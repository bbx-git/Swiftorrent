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
    /// Upper bound on peers seeded into the swarm reserve up front. The reserve is
    /// then kept topped up by inbound PEX and the supervisor's periodic re-announce,
    /// so this only caps the *initial* set, not the total peers ever tried.
    private let maxSwarmReservePeers = 300
    /// Concurrent peer connections — a large pool like a mainstream client (qBittorrent
    /// defaults to ~100 per torrent). A download-only client is kept choked by most
    /// peers (no tit-for-tat credit), so aggregate throughput tracks how many
    /// *unchoking* seeds we hold at once; holding many connections open (they persist
    /// through chokes, see `PeerWireClient.idleTimeoutSeconds`) maximises the chance
    /// that enough of them are seeds actively feeding us.
    private let maxPeerConnections = 100
    /// Start the swarm as soon as discovery has this many peers instead of waiting
    /// for every tracker and the DHT to finish, so the first byte isn't gated on
    /// the slowest source.
    private static let enoughPeersToStart = 100
    /// Hard cap on initial peer discovery; late peers (incl. the DHT) still arrive
    /// via the swarm supervisor's periodic re-announce.
    private static let peerDiscoveryDeadline: Duration = .seconds(12)
    /// Once this short grace period has elapsed, stop waiting for stragglers (in
    /// practice almost always the DHT, which the swarm supervisor's re-announce
    /// will fold in later anyway) as soon as *any* peer is known — trackers
    /// typically answer in well under a second, so gating first byte on the DHT's
    /// much slower query budget wastes most of `peerDiscoveryDeadline` for no
    /// benefit. A pure-DHT magnet (no trackers, zero peers yet) is unaffected:
    /// this only fires once at least one peer has already been found.
    private static let fastStartDeadline: Duration = .seconds(3)

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
        var verifiedPieces = try await writer.verifiedPiecesConcurrently(among: selectablePieces)
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
                verifiedPieces.formUnion(try await writer.verifiedPiecesConcurrently(among: unverified))
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
        // Pause, removal, quit and failure all end the run without `completed`;
        // tell the tracker so it drops us instead of listing us until it times out.
        do {
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
                await announceStopped(for: metainfo, peerID: peerID, downloaded: verifiedBytes)
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
                peers: Array(peers.shuffled().prefix(maxSwarmReservePeers)),
                peerID: peerID,
                verifiedPieces: verifiedPieces,
                initialDownloaded: verifiedBytes,
                stripRootDirectory: stripRootDirectory,
                // Periodic re-announce so the swarm reserve never permanently runs dry:
                // a fresh tracker/DHT lookup (no event — an interval refresh, not
                // started/stopped) whose peers the supervisor folds into the reserve.
                // Download-only is preserved: port 0, uploaded 0, as in every announce.
                refillPeers: {
                    (try? await self.collectPeers(
                        for: metainfo,
                        peerID: peerID,
                        downloaded: verifiedBytes,
                        left: downloadTotal - verifiedBytes,
                        event: nil
                    )) ?? []
                },
                progress: progress
            )
            try writer.finalize(selectedFileIDs: selection)
            await announceStopped(for: metainfo, peerID: peerID, downloaded: downloaded)
            await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: downloadTotal, totalBytes: downloadTotal, files: fileSnapshot(for: selectablePieces)))
        } catch {
            let metainfo = metainfo, left = downloadTotal - initialDownloaded
            // Detached: this task is usually cancelled, which would abort the announce.
            await Task.detached {
                await self.announceStopped(for: metainfo, peerID: peerID, downloaded: initialDownloaded, left: left)
            }.value
            throw error
        }
    }

    /// Best-effort final announce. Capped so a slow or dead tracker can't delay
    /// "Complete" by the full discovery deadline.
    func announceStopped(
        for metainfo: TorrentMetainfo,
        peerID: Data,
        downloaded: Int64,
        left: Int64 = 0,
        cap: Duration = .seconds(3)
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: downloaded, left: left, event: "stopped", includeDHT: false)
            }
            group.addTask {
                try? await Task.sleep(for: cap)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// A peer-discovery signal: peers streamed in by the DHT, a source (tracker
    /// or DHT) reporting its final result, the short fast-start grace period
    /// elapsing, or the hard deadline firing.
    private enum CollectSignal {
        case streamed([PeerEndpoint])
        case source(Result<[PeerEndpoint], Error>)
        case fastStartElapsed
        case deadline
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
        // Sources push into one stream so the DHT can report peers batch by batch
        // while its walk is still running (a task-group child returns only once).
        let (signals, continuation) = AsyncStream.makeStream(of: CollectSignal.self)

        await withTaskGroup(of: Void.self) { group in
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
                        continuation.yield(.source(.success(try await trackerClient.announce(request))))
                    } catch {
                        continuation.yield(.source(.failure(error)))
                    }
                }
            }

            if includeDHT {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let all = try await dhtClient.peers(for: metainfo.infoHash, onPeers: { continuation.yield(.streamed($0)) })
                        continuation.yield(.source(.success(all)))
                    } catch {
                        continuation.yield(.source(.failure(error)))
                    }
                }
            }

            // Fast-start sentinel: once this short grace period elapses, stop
            // waiting on stragglers (usually the DHT) as soon as we already have
            // some peers to work with.
            group.addTask {
                try? await Task.sleep(for: Self.fastStartDeadline)
                if !Task.isCancelled { continuation.yield(.fastStartElapsed) }
            }

            // Deadline sentinel: don't let the whole download wait on the slowest
            // source (usually the DHT). We stop early once we have enough peers, all
            // real sources have reported, the fast-start grace period has passed
            // with peers in hand, or this fires — whichever comes first.
            group.addTask {
                try? await Task.sleep(for: Self.peerDiscoveryDeadline)
                if !Task.isCancelled { continuation.yield(.deadline) }
            }

            let realSources = metainfo.announceURLs.count + (includeDHT ? 1 : 0)
            var reported = 0
            var fastStartElapsed = false
            collectLoop: for await signal in signals {
                if Task.isCancelled {
                    break collectLoop
                }
                switch signal {
                case .deadline:
                    break collectLoop
                case .fastStartElapsed:
                    fastStartElapsed = true
                case let .streamed(endpoints):
                    peers.formUnion(endpoints)
                case let .source(result):
                    reported += 1
                    switch result {
                    case let .success(endpoints):
                        peers.formUnion(endpoints)
                    case let .failure(error):
                        lastError = error
                    }
                }
                // Stop as soon as we have plenty, every tracker/DHT has answered, or
                // the fast-start grace period has passed and we already have some
                // peers (so first byte isn't gated on a slow straggler, typically
                // the DHT — its later peers still arrive via the swarm supervisor's
                // periodic re-announce).
                if peers.count >= Self.enoughPeersToStart || reported >= realSources || (fastStartElapsed && !peers.isEmpty) {
                    break collectLoop
                }
            }
            continuation.finish()
            group.cancelAll()
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
    func peers(for infoHash: Data, onPeers: @Sendable ([PeerEndpoint]) async -> Void) async throws -> [PeerEndpoint]
}

extension DHTClient: DHTPeerFinding {}
