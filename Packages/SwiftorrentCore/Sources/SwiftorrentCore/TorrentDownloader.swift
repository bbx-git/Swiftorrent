import CryptoKit
import Foundation

public struct TorrentFileProgress: Sendable, Identifiable, Equatable {
    public let id: Int
    public let path: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let isSelected: Bool

    public init(id: Int, path: String, downloadedBytes: Int64, totalBytes: Int64, isSelected: Bool) {
        self.id = id
        self.path = path
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isSelected = isSelected
    }
}

public struct TorrentDownloadProgress: Sendable {
    public let status: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    /// Per-file breakdown. Empty means "no change since the last update" so the
    /// frequent status-only ticks (connecting, contacting trackers) don't have
    /// to recompute the whole table; consumers keep the last non-empty value.
    public let files: [TorrentFileProgress]

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public init(status: String, downloadedBytes: Int64, totalBytes: Int64, files: [TorrentFileProgress] = []) {
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.files = files
    }
}

public struct TorrentDownloader: Sendable {
    private let trackerClient: any TrackerAnnouncing
    private let dhtClient: any DHTPeerFinding
    private let session: URLSession
    private let maxPeerAttempts = 24
    private let maxPeerConnections = 4

    public init(trackerClient: TrackerClient = TrackerClient(), dhtClient: DHTClient = DHTClient(), session: URLSession = .shared) {
        self.trackerClient = trackerClient
        self.dhtClient = dhtClient
        self.session = session
    }

    init(trackerClient: any TrackerAnnouncing, dhtClient: any DHTPeerFinding, session: URLSession = .shared) {
        self.trackerClient = trackerClient
        self.dhtClient = dhtClient
        self.session = session
    }

    public func download(
        metainfo: TorrentMetainfo,
        destination: URL,
        selectedFileIDs: Set<Int>? = nil,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
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

        guard !selectablePieces.isEmpty, downloadTotal > 0 else {
            await progress(TorrentDownloadProgress(status: "No files selected.", downloadedBytes: 0, totalBytes: 0, files: fileProgress(metainfo: metainfo, selection: selection, perFileBytes: [Int64](repeating: 0, count: metainfo.files.count))))
            return
        }

        func fileSnapshot(for pieces: Set<Int>) -> [TorrentFileProgress] {
            fileProgress(metainfo: metainfo, selection: selection, perFileBytes: layout.completedBytesPerFile(completedPieces: pieces))
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

        // Web seeds fetch whole files over HTTP, which cannot satisfy the
        // boundary pieces a partial selection needs, so the optimization only
        // applies to a full download.
        if isFullSelection, !metainfo.webSeedURLs.isEmpty {
            do {
                try await downloadFromWebSeeds(
                    metainfo: metainfo,
                    writer: writer,
                    layout: layout,
                    selection: selection,
                    initialDownloaded: initialDownloaded,
                    totalBytes: downloadTotal,
                    progress: progress
                )
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
        do {
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

            let downloaded = try await downloadPiecesConcurrently(
                metainfo: metainfo,
                destination: destination,
                layout: layout,
                selectablePieces: selectablePieces,
                selection: selection,
                downloadTotal: downloadTotal,
                peers: Array(peers.shuffled().prefix(maxPeerAttempts)),
                peerID: peerID,
                verifiedPieces: verifiedPieces,
                initialDownloaded: verifiedBytes,
                progress: progress
            )
            try writer.finalize(selectedFileIDs: selection)
            _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: downloaded, left: 0, event: "stopped", includeDHT: false)
            await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: downloadTotal, totalBytes: downloadTotal, files: fileSnapshot(for: selectablePieces)))
            return
        }
    }

    private func fileProgress(metainfo: TorrentMetainfo, selection: Set<Int>, perFileBytes: [Int64]) -> [TorrentFileProgress] {
        metainfo.files.map { file in
            let done = file.id < perFileBytes.count ? min(perFileBytes[file.id], file.length) : 0
            return TorrentFileProgress(
                id: file.id,
                path: file.path,
                downloadedBytes: done,
                totalBytes: file.length,
                isSelected: selection.contains(file.id)
            )
        }
    }

    private func downloadFromWebSeeds(
        metainfo: TorrentMetainfo,
        writer: TorrentFileWriter,
        layout: TorrentLayout,
        selection: Set<Int>,
        initialDownloaded: Int64,
        totalBytes: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        var lastError: Error?
        for webSeedURL in metainfo.webSeedURLs {
            try Task.checkCancellation()
            do {
                var downloadedBytes = initialDownloaded
                var perFileBytes = [Int64](repeating: 0, count: metainfo.files.count)
                for file in metainfo.files {
                    try Task.checkCancellation()
                    let sourceURL = webSeedURL.appendingTorrentRelativePath(file.path)
                    let fileBase = downloadedBytes
                    let baseFileBytes = perFileBytes
                    let snapshot: @Sendable (Int64) -> [TorrentFileProgress] = { currentFileBytes in
                        var bytes = baseFileBytes
                        if file.id < bytes.count { bytes[file.id] = min(currentFileBytes, file.length) }
                        return self.fileProgress(metainfo: metainfo, selection: selection, perFileBytes: bytes)
                    }
                    await progress(TorrentDownloadProgress(status: "Downloading from web seed: \(file.path)", downloadedBytes: downloadedBytes, totalBytes: totalBytes, files: snapshot(0)))
                    downloadedBytes += try await downloadWebSeedFile(from: sourceURL, file: file, writer: writer, progressDownloadedBytes: downloadedBytes) { currentDownloadedBytes in
                        await progress(TorrentDownloadProgress(status: "Downloading from web seed: \(file.path)", downloadedBytes: currentDownloadedBytes, totalBytes: totalBytes, files: snapshot(currentDownloadedBytes - fileBase)))
                    }
                    if file.id < perFileBytes.count { perFileBytes[file.id] = file.length }
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TrackerClientError.invalidResponse
    }

    private func downloadWebSeedFile(
        from sourceURL: URL,
        file: TorrentFile,
        writer: TorrentFileWriter,
        progressDownloadedBytes: Int64,
        progress: @Sendable @escaping (Int64) async -> Void
    ) async throws -> Int64 {
        let (partialURL, resumeOffset) = try writer.partialFileResumeOffset(for: file)
        // Already fully present from a prior run; nothing to fetch.
        if resumeOffset >= file.length {
            return file.length
        }

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackerClientError.invalidResponse
        }

        // Honor the server's decision: 206 means our range was accepted, so we
        // append; 200 means the range was ignored and the whole body follows, so
        // we rewrite from the start. Anything else is treated as a failure and
        // the caller falls through to the next web seed / peers.
        let writeOffset: Int64
        switch httpResponse.statusCode {
        case 206:
            writeOffset = resumeOffset
        case 200:
            writeOffset = 0
        default:
            throw TrackerClientError.invalidResponse
        }

        let handle = try FileHandle(forWritingTo: partialURL)
        var fileDownloadedBytes: Int64 = writeOffset
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        do {
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(writeOffset))
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    fileDownloadedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    await progress(progressDownloadedBytes + fileDownloadedBytes)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                fileDownloadedBytes += Int64(buffer.count)
                await progress(progressDownloadedBytes + fileDownloadedBytes)
            }
        } catch { throw error }

        // `fileDownloadedBytes` started at `writeOffset`, so it now reflects the
        // whole file present on disk, including any resumed prefix.
        guard fileDownloadedBytes == file.length else {
            throw TrackerClientError.invalidResponse
        }
        return file.length
    }

    private func downloadPiecesConcurrently(
        metainfo: TorrentMetainfo,
        destination: URL,
        layout: TorrentLayout,
        selectablePieces: Set<Int>,
        selection: Set<Int>,
        downloadTotal: Int64,
        peers: [PeerEndpoint],
        peerID: Data,
        verifiedPieces: Set<Int>,
        initialDownloaded: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws -> Int64 {
        let sessions = try await connectPeerSessions(
            peers: peers,
            metainfo: metainfo,
            peerID: peerID,
            initialDownloaded: initialDownloaded,
            totalBytes: downloadTotal,
            progress: progress
        )
        guard !sessions.isEmpty else { throw TrackerClientError.invalidResponse }

        let writer = TorrentPieceWriter(writer: TorrentFileWriter(metainfo: metainfo, destination: destination))
        let coordinator = PieceDownloadCoordinator(
            layout: layout,
            selectablePieces: selectablePieces,
            completedPieces: verifiedPieces,
            initialDownloaded: initialDownloaded,
            availabilityCounts: availabilityCounts(from: sessions)
        )
        @Sendable func fileSnapshot(_ perFileBytes: [Int64]) -> [TorrentFileProgress] {
            fileProgress(metainfo: metainfo, selection: selection, perFileBytes: perFileBytes)
        }

        var lastError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for session in sessions {
                group.addTask {
                    await progress(TorrentDownloadProgress(status: "Connected to peer \(session.endpoint.host):\(session.endpoint.port)", downloadedBytes: initialDownloaded, totalBytes: downloadTotal))
                    while true {
                        try? Task.checkCancellation()
                        guard !Task.isCancelled else { return CancellationError() }
                        // Pull live availability each pass so `have`/`bitfield`
                        // messages received mid-download refine the set. When the
                        // peer never declared availability (unchoked first), fall
                        // back optimistically to all pieces; this self-corrects as
                        // soon as the peer announces anything.
                        let (livePieces, isKnown) = await session.client.currentAvailability()
                        let usablePieces = isKnown ? livePieces : selectablePieces
                        guard let pieceIndex = await coordinator.nextPiece(availablePieces: usablePieces) else {
                            return nil
                        }

                        do {
                            let length = layout.length(ofPiece: pieceIndex)
                            await progress(TorrentDownloadProgress(status: "Downloading piece \(pieceIndex + 1) of \(metainfo.pieceHashes.count)", downloadedBytes: await coordinator.downloadedBytes, totalBytes: downloadTotal))
                            let piece = try await withTimeout(seconds: .seconds(60)) {
                                try await session.client.downloadPiece(index: pieceIndex, length: length, expectedHash: metainfo.pieceHashes[pieceIndex])
                            }
                            try await writer.write(piece: piece, pieceIndex: pieceIndex)
                            let (downloaded, perFileBytes) = await coordinator.complete(pieceIndex: pieceIndex)
                            await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: downloaded, totalBytes: downloadTotal, files: fileSnapshot(perFileBytes)))
                        } catch is CancellationError {
                            await coordinator.returnPiece(pieceIndex)
                            return CancellationError()
                        } catch {
                            await coordinator.returnPiece(pieceIndex)
                            await progress(TorrentDownloadProgress(status: "Peer \(session.endpoint.host):\(session.endpoint.port) failed piece \(pieceIndex + 1).", downloadedBytes: await coordinator.downloadedBytes, totalBytes: downloadTotal))
                            return error
                        }
                    }
                }
            }

            for await result in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let result {
                    lastError = result
                }
            }
        }

        let downloadedBytes = await coordinator.isComplete ? await coordinator.downloadedBytes : nil
        await closeSessions(sessions)
        if let downloadedBytes {
            return downloadedBytes
        }
        throw lastError ?? TrackerClientError.invalidResponse
    }

    private func closeSessions(_ sessions: [PeerDownloadSession]) async {
        for session in sessions {
            await session.client.close()
        }
    }

    private func connectPeerSessions(
        peers: [PeerEndpoint],
        metainfo: TorrentMetainfo,
        peerID: Data,
        initialDownloaded: Int64,
        totalBytes: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws -> [PeerDownloadSession] {
        var sessions: [PeerDownloadSession] = []
        var lastError: Error?

        await withTaskGroup(of: Result<PeerDownloadSession, Error>.self) { group in
            for peer in peers {
                group.addTask {
                    let client = PeerWireClient(endpoint: peer, infoHash: metainfo.infoHash, peerID: peerID)
                    do {
                        try Task.checkCancellation()
                        await progress(TorrentDownloadProgress(status: "Connecting to peer \(peer.host):\(peer.port)", downloadedBytes: initialDownloaded, totalBytes: totalBytes))
                        try await withTimeout(seconds: .seconds(20)) {
                            try await client.connect()
                        }
                        let available = try await withTimeout(seconds: .seconds(10)) {
                            try await client.readInitialAvailability(pieceCount: metainfo.pieceHashes.count)
                        }
                        // Snapshot used only to seed rarest-first counts; the
                        // live set is queried per piece during the download loop.
                        // An undeclared (empty) peer counts optimistically as a
                        // full seed for rarest-first seeding purposes.
                        return .success(PeerDownloadSession(
                            endpoint: peer,
                            client: client,
                            availablePieces: available.isEmpty ? Set(metainfo.pieceHashes.indices) : available
                        ))
                    } catch {
                        await client.close()
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
                case let .success(session):
                    if sessions.count < maxPeerConnections {
                        sessions.append(session)
                    } else {
                        await session.client.close()
                    }
                    if sessions.count == maxPeerConnections {
                        group.cancelAll()
                    }
                case let .failure(error):
                    lastError = error
                }
            }
        }

        try Task.checkCancellation()
        if sessions.isEmpty, let lastError {
            throw lastError
        }
        return sessions
    }

    private func availabilityCounts(from sessions: [PeerDownloadSession]) -> [Int: Int] {
        sessions.reduce(into: [Int: Int]()) { counts, session in
            for piece in session.availablePieces {
                counts[piece, default: 0] += 1
            }
        }
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

private extension URL {
    func appendingTorrentRelativePath(_ path: String) -> URL {
        path.split(separator: "/").reduce(self) { url, component in
            url.appendingPathComponent(String(component))
        }
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

private struct PeerDownloadSession: Sendable {
    let endpoint: PeerEndpoint
    let client: PeerWireClient
    let availablePieces: Set<Int>
}

private actor TorrentPieceWriter {
    private let writer: TorrentFileWriter

    init(writer: TorrentFileWriter) {
        self.writer = writer
    }

    func write(piece: Data, pieceIndex: Int) throws {
        try writer.write(piece: piece, pieceIndex: pieceIndex)
    }
}

private actor PieceDownloadCoordinator {
    private let layout: TorrentLayout
    private let availabilityCounts: [Int: Int]
    private var pendingPieces: Set<Int>
    private var activePieces = Set<Int>()
    private var completedPieces: Set<Int>
    private var completedBytes: Int64
    private var perFileBytes: [Int64]

    init(layout: TorrentLayout, selectablePieces: Set<Int>, completedPieces: Set<Int>, initialDownloaded: Int64, availabilityCounts: [Int: Int]) {
        self.layout = layout
        self.completedPieces = completedPieces
        self.completedBytes = initialDownloaded
        self.availabilityCounts = availabilityCounts
        self.pendingPieces = selectablePieces.subtracting(completedPieces)
        self.perFileBytes = layout.completedBytesPerFile(completedPieces: completedPieces)
    }

    var downloadedBytes: Int64 {
        completedBytes
    }

    var isComplete: Bool {
        pendingPieces.isEmpty && activePieces.isEmpty
    }

    func nextPiece(availablePieces: Set<Int>) -> Int? {
        let candidates = pendingPieces.intersection(availablePieces)
        guard let piece = candidates.min(by: { left, right in
            let leftCount = availabilityCounts[left, default: Int.max]
            let rightCount = availabilityCounts[right, default: Int.max]
            if leftCount == rightCount { return left < right }
            return leftCount < rightCount
        }) else {
            return nil
        }
        pendingPieces.remove(piece)
        activePieces.insert(piece)
        return piece
    }

    func complete(pieceIndex: Int) -> (downloadedBytes: Int64, perFileBytes: [Int64]) {
        guard activePieces.remove(pieceIndex) != nil, !completedPieces.contains(pieceIndex) else {
            return (completedBytes, perFileBytes)
        }
        completedPieces.insert(pieceIndex)
        completedBytes += Int64(layout.length(ofPiece: pieceIndex))
        // Fold just this piece's slices into the running per-file tally instead
        // of recomputing the whole table each completion.
        for (id, bytes) in layout.completedBytesPerFile(completedPieces: [pieceIndex]).enumerated() where bytes > 0 {
            perFileBytes[id] += bytes
        }
        return (completedBytes, perFileBytes)
    }

    func returnPiece(_ pieceIndex: Int) {
        guard activePieces.remove(pieceIndex) != nil, !completedPieces.contains(pieceIndex) else {
            return
        }
        pendingPieces.insert(pieceIndex)
    }
}

struct TorrentFileWriter: Sendable {
    let metainfo: TorrentMetainfo
    let destination: URL
    private let partialExtension = "tor"

    func verifiedPieces() throws -> Set<Int> {
        try verifiedPieces(among: metainfo.pieceHashes.indices)
    }

    /// Verifies only `indices` against their expected hashes, returning the
    /// subset that is present on disk and matches. Reading + SHA-1 hashing a
    /// piece is expensive, so callers that already hold a cached verified set
    /// pass just the still-unverified indices here to refresh it after new
    /// pieces are written, instead of re-hashing the entire dataset.
    func verifiedPieces<S: Sequence>(among indices: S) throws -> Set<Int> where S.Element == Int {
        var verified = Set<Int>()
        for pieceIndex in indices {
            let length = pieceLength(for: pieceIndex)
            guard let piece = try read(pieceIndex: pieceIndex, length: length),
                  Data(Insecure.SHA1.hash(data: piece)) == metainfo.pieceHashes[pieceIndex] else {
                continue
            }
            verified.insert(pieceIndex)
        }
        return verified
    }

    func write(piece: Data, pieceIndex: Int) throws {
        let pieceStart = Int64(pieceIndex * metainfo.pieceLength)
        var remaining = piece
        var offsetInTorrent = pieceStart

        for file in metainfo.files {
            let fileStart = metainfo.files.prefix(file.id).reduce(Int64(0)) { $0 + $1.length }
            let fileEnd = fileStart + file.length
            guard offsetInTorrent < fileEnd, offsetInTorrent + Int64(remaining.count) > fileStart else {
                continue
            }

            let localStart = max(offsetInTorrent, fileStart)
            let localEnd = min(offsetInTorrent + Int64(remaining.count), fileEnd)
            let count = Int(localEnd - localStart)
            let sourceOffset = Int(localStart - offsetInTorrent)
            let chunkStart = remaining.index(remaining.startIndex, offsetBy: sourceOffset)
            let chunkEnd = remaining.index(chunkStart, offsetBy: count)
            let chunk = Data(remaining[chunkStart..<chunkEnd])
            try write(chunk: chunk, to: file, at: localStart - fileStart)
            remaining.removeFirst(sourceOffset + count)
            offsetInTorrent = localEnd
            if remaining.isEmpty { break }
        }
    }

    func finalize() throws {
        try finalize(selectedFileIDs: Set(metainfo.files.map(\.id)))
    }

    /// Promotes the selected files' `.tor` partials to their final names. A
    /// deselected file may still hold a small `.tor` partial of bytes from a
    /// boundary piece it shares with a selected neighbor; those are removed so
    /// the destination ends up with exactly the selected files.
    func finalize(selectedFileIDs: Set<Int>) throws {
        for file in metainfo.files {
            let partialURL = try outputURL(for: file, partial: true)
            guard FileManager.default.fileExists(atPath: partialURL.path) else {
                continue
            }

            guard selectedFileIDs.contains(file.id) else {
                try? FileManager.default.removeItem(at: partialURL)
                continue
            }

            let finalURL = try outputURL(for: file, partial: false)
            try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        }
    }

    func preparePartialFile(for file: TorrentFile) throws -> URL {
        let partialURL = try outputURL(for: file, partial: true)
        try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: partialURL.path) {
            try FileManager.default.removeItem(at: partialURL)
        }
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        return partialURL
    }

    /// Determines where an interrupted web-seed download of `file` should resume.
    /// Returns the URL to append to and the byte offset already on disk, so the
    /// caller can issue an HTTP `Range: bytes=offset-` request instead of
    /// refetching the whole file. Behavior by existing state:
    /// - Partial `.tor` present and not oversized → resume from its length.
    /// - Partial present but larger than `file.length` (corrupt) → truncate, start at 0.
    /// - No partial but a completed final file → report `file.length` so the
    ///   caller can skip the fetch entirely (no wasteful copy).
    /// - Nothing present → fresh empty partial, start at 0.
    func partialFileResumeOffset(for file: TorrentFile) throws -> (url: URL, offset: Int64) {
        let partialURL = try outputURL(for: file, partial: true)
        let finalURL = try outputURL(for: file, partial: false)
        try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: partialURL.path) {
            let size = try fileSize(at: partialURL)
            if size > file.length {
                try FileManager.default.removeItem(at: partialURL)
                FileManager.default.createFile(atPath: partialURL.path, contents: nil)
                return (partialURL, 0)
            }
            return (partialURL, size)
        }

        if FileManager.default.fileExists(atPath: finalURL.path),
           try fileSize(at: finalURL) >= file.length {
            return (finalURL, file.length)
        }

        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        return (partialURL, 0)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    func read(pieceIndex: Int, length: Int) throws -> Data? {
        let pieceStart = Int64(pieceIndex * metainfo.pieceLength)
        var result = Data()
        result.reserveCapacity(length)
        let pieceEnd = pieceStart + Int64(length)

        for file in metainfo.files {
            let fileStart = metainfo.files.prefix(file.id).reduce(Int64(0)) { $0 + $1.length }
            let fileEnd = fileStart + file.length
            guard pieceStart < fileEnd, pieceEnd > fileStart else {
                continue
            }

            let localStart = max(pieceStart, fileStart)
            let localEnd = min(pieceEnd, fileEnd)
            let count = Int(localEnd - localStart)
            let chunk = try readChunk(from: file, at: localStart - fileStart, count: count)
            guard let chunk, chunk.count == count else {
                return nil
            }
            result.append(chunk)
        }

        return result.count == length ? result : nil
    }

    private func write(chunk: Data, to file: TorrentFile, at offset: Int64) throws {
        let url = try outputURL(for: file, partial: true)
        let finalURL = try outputURL(for: file, partial: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.copyItem(at: finalURL, to: url)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: chunk)
    }

    private func readChunk(from file: TorrentFile, at offset: Int64, count: Int) throws -> Data? {
        let partialURL = try outputURL(for: file, partial: true)
        let finalURL = try outputURL(for: file, partial: false)
        let url = FileManager.default.fileExists(atPath: partialURL.path) ? partialURL : finalURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count)
    }

    private func pieceLength(for index: Int) -> Int {
        if index == metainfo.pieceHashes.count - 1 {
            let consumed = Int64(index * metainfo.pieceLength)
            return Int(metainfo.totalSize - consumed)
        }
        return metainfo.pieceLength
    }

    private func outputURL(for file: TorrentFile, partial: Bool) throws -> URL {
        let destinationURL = destination.standardizedFileURL
        let finalURL = destinationURL.appendingPathComponent(file.path)
        let outputURL = (partial ? finalURL.appendingPathExtension(partialExtension) : finalURL).standardizedFileURL
        let destinationPath = destinationURL.path
        let outputPath = outputURL.path
        guard outputPath == destinationPath || outputPath.hasPrefix(destinationPath + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return outputURL
    }
}
