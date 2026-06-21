import Foundation

/// Orchestrates a download-only torrent transfer. Resolves the file selection
/// into a set of pieces, verifies what is already on disk, then tries web seeds
/// first and falls back to the peer swarm. Delegates the actual transfers to
/// `WebSeedDownloader` and `PeerSwarmDownloader`; peer discovery runs through
/// `collectPeers`. Never seeds: the tracker port is 0, `uploaded` is always 0,
/// and completion sends a best-effort stopped announce.
public struct TorrentDownloader: Sendable {
    private let trackerClient: any TrackerAnnouncing
    private let dhtClient: any DHTPeerFinding
    private let session: URLSession
    /// Shared throughput cap applied across every concurrent download path. When
    /// `nil` no limiting is applied.
    private let rateLimiter: RateLimiter?
    private let maxPeerAttempts = 24
    private let maxPeerConnections = 4

    public init(trackerClient: TrackerClient = TrackerClient(), dhtClient: DHTClient = DHTClient(), session: URLSession = .shared, rateLimiter: RateLimiter? = nil) {
        self.trackerClient = trackerClient
        self.dhtClient = dhtClient
        self.session = session
        self.rateLimiter = rateLimiter
    }

    init(trackerClient: any TrackerAnnouncing, dhtClient: any DHTPeerFinding, session: URLSession = .shared, rateLimiter: RateLimiter? = nil) {
        self.trackerClient = trackerClient
        self.dhtClient = dhtClient
        self.session = session
        self.rateLimiter = rateLimiter
    }

    public func download(
        metainfo: TorrentMetainfo,
        destination: URL,
        selectedFileIDs: Set<Int>? = nil,
        stripRootDirectory: Bool = false,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination, stripRootDirectory: stripRootDirectory)
        let layout = TorrentLayout(metainfo: metainfo)

        // Resolve the selection into the set of pieces we actually fetch. A full
        // selection downloads every piece; a subset downloads only the pieces
        // overlapping the chosen files (including boundary pieces shared with a
        // deselected neighbor, which must be whole to verify the selected edge).
        let allFileIDs = Set(metainfo.files.map(\.id))
        let selection = selectedFileIDs ?? allFileIDs
        let isFullSelection = selection.isSuperset(of: allFileIDs)
        let selectablePieces = isFullSelection
            ? Set(0..<layout.pieceCount)
            : layout.pieceIndices(forFiles: selection)
        let downloadTotal = selectablePieces.reduce(Int64(0)) { $0 + Int64(layout.length(ofPiece: $1)) }
        let mapper = FileProgressMapper(metainfo: metainfo, selection: selection)

        guard !selectablePieces.isEmpty, downloadTotal > 0 else {
            await progress(TorrentDownloadProgress(status: "No files selected.", downloadedBytes: 0, totalBytes: 0, files: mapper.empty()))
            return
        }

        func fileSnapshot(for pieces: Set<Int>) -> [TorrentFileProgress] {
            mapper.snapshot(perFileBytes: layout.completedBytesPerFile(completedPieces: pieces))
        }

        // Full hash scan once over the selected pieces. `verifiedPieces` is then
        // carried forward and only refreshed for pieces written during this run,
        // so we never re-hash already-valid pieces on the paths below.
        var verifiedPieces = try writer.verifiedPieces(among: selectablePieces)
        let initialDownloaded = bytesCompleted(for: verifiedPieces, layout: layout)
        try ensureAvailableCapacity(for: downloadTotal - initialDownloaded, at: destination)

        if initialDownloaded >= downloadTotal {
            try writer.finalize(selectedFileIDs: selection)
            await progress(TorrentDownloadProgress(status: "Complete. Existing files verified. No seeding.", downloadedBytes: downloadTotal, totalBytes: downloadTotal, files: fileSnapshot(for: verifiedPieces)))
            return
        }

        // Web seeds fetch over HTTP. A full download streams each whole file; a
        // partial download fetches only the selected files plus the small slices
        // of any boundary piece that belong to a deselected neighbor (so the
        // shared piece still verifies). Either way, completed pieces are folded
        // into `verifiedPieces` below.
        if !metainfo.webSeedURLs.isEmpty {
            do {
                let webSeeds = WebSeedDownloader(session: session, rateLimiter: rateLimiter)
                if isFullSelection {
                    try await webSeeds.downloadAll(
                        metainfo: metainfo,
                        writer: writer,
                        mapper: mapper,
                        initialDownloaded: initialDownloaded,
                        totalBytes: downloadTotal,
                        progress: progress
                    )
                } else {
                    try await webSeeds.downloadSelected(
                        metainfo: metainfo,
                        writer: writer,
                        layout: layout,
                        selection: selection,
                        selectablePieces: selectablePieces,
                        mapper: mapper,
                        initialDownloaded: initialDownloaded,
                        totalBytes: downloadTotal,
                        progress: progress
                    )
                }
                // Web seeds only write pieces we did not already have, so verify
                // just the previously-unverified indices and fold the result in.
                let unverified = selectablePieces.subtracting(verifiedPieces)
                verifiedPieces.formUnion(try writer.verifiedPieces(among: unverified))
                let verifiedBytes = bytesCompleted(for: verifiedPieces, layout: layout)
                if verifiedBytes >= downloadTotal {
                    try writer.finalize(selectedFileIDs: selection)
                    await progress(TorrentDownloadProgress(status: "Complete. Downloaded from web seed. No seeding.", downloadedBytes: downloadTotal, totalBytes: downloadTotal, files: fileSnapshot(for: verifiedPieces)))
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await progress(TorrentDownloadProgress(status: "Web seed failed. Contacting trackers and DHT", downloadedBytes: initialDownloaded, totalBytes: downloadTotal))
            }
        }

        let peerID = Self.makePeerID()
        await progress(TorrentDownloadProgress(status: "Verified existing data. Contacting trackers and DHT", downloadedBytes: initialDownloaded, totalBytes: downloadTotal, files: fileSnapshot(for: verifiedPieces)))
        let peers = try await collectPeers(for: metainfo, peerID: peerID, downloaded: initialDownloaded, left: downloadTotal - initialDownloaded, event: "started")
        try Task.checkCancellation()
        guard !peers.isEmpty else {
            throw TrackerClientError.invalidResponse
        }

        // Nothing writes to disk between the scan above and here (peer
        // discovery does no I/O), so the cached set is still accurate.
        let verifiedBytes = bytesCompleted(for: verifiedPieces, layout: layout)
        if verifiedBytes >= downloadTotal {
            try writer.finalize(selectedFileIDs: selection)
            _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: verifiedBytes, left: 0, event: "stopped", includeDHT: false)
            await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: downloadTotal, totalBytes: downloadTotal, files: fileSnapshot(for: verifiedPieces)))
            return
        }

        let downloaded = try await PeerSwarmDownloader(maxPeerConnections: maxPeerConnections, rateLimiter: rateLimiter).download(
            metainfo: metainfo,
            destination: destination,
            layout: layout,
            selectablePieces: selectablePieces,
            mapper: mapper,
            downloadTotal: downloadTotal,
            peers: Array(peers.shuffled().prefix(maxPeerAttempts)),
            peerID: peerID,
            verifiedPieces: verifiedPieces,
            initialDownloaded: verifiedBytes,
            stripRootDirectory: stripRootDirectory,
            progress: progress
        )
        try writer.finalize(selectedFileIDs: selection)
        _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: downloaded, left: 0, event: "stopped", includeDHT: false)
        await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: downloadTotal, totalBytes: downloadTotal, files: fileSnapshot(for: selectablePieces)))
    }

    func collectPeers(
        for metainfo: TorrentMetainfo,
        peerID: Data,
        downloaded: Int64 = 0,
        left: Int64? = nil,
        event: String?,
        includeDHT: Bool = true
    ) async throws -> [PeerEndpoint] {
        var peers: Set<PeerEndpoint> = []
        var lastError: Error?

        await withTaskGroup(of: Result<[PeerEndpoint], Error>.self) { group in
            for url in metainfo.announceURLs {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let request = TrackerRequest(
                            announceURL: url,
                            infoHash: metainfo.infoHash,
                            peerID: peerID,
                            downloaded: downloaded,
                            left: left ?? metainfo.totalSize,
                            event: event
                        )
                        return .success(try await trackerClient.announce(request))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            if includeDHT {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return .success(try await dhtClient.peers(for: metainfo.infoHash))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                switch result {
                case let .success(endpoints):
                    peers.formUnion(endpoints)
                case let .failure(error):
                    lastError = error
                }
            }
        }

        try Task.checkCancellation()
        if peers.isEmpty, let lastError {
            throw lastError
        }
        return Array(peers).shuffled()
    }

    private func bytesCompleted(for pieces: Set<Int>, layout: TorrentLayout) -> Int64 {
        pieces.reduce(Int64(0)) { total, pieceIndex in
            total + Int64(layout.length(ofPiece: pieceIndex))
        }
    }

    private func ensureAvailableCapacity(for bytes: Int64, at destination: URL) throws {
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < bytes {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    public static func makePeerID() -> Data {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        // The identifier is ASCII by construction (hex suffix + literals), so
        // `utf8` yields exactly its bytes and never traps — unlike a
        // force-unwrapped `data(using: .ascii)`. Pad/truncate to the required
        // 20-byte peer id defensively in case the prefix is ever shortened.
        var data = Data("-SW0001-\(suffix)0000".utf8.prefix(20))
        if data.count < 20 {
            data.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: 20 - data.count))
        }
        return data
    }
}

protocol TrackerAnnouncing: Sendable {
    func announce(_ request: TrackerRequest) async throws -> [PeerEndpoint]
}

extension TrackerClient: TrackerAnnouncing {}

protocol DHTPeerFinding: Sendable {
    func peers(for infoHash: Data) async throws -> [PeerEndpoint]
}

extension DHTClient: DHTPeerFinding {}
