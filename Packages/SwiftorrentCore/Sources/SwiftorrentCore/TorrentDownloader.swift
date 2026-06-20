import CryptoKit
import Foundation

public struct TorrentDownloadProgress: Sendable {
    public let status: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public init(status: String, downloadedBytes: Int64, totalBytes: Int64) {
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
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
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        // Full hash scan once. `verifiedPieces` is then carried forward and only
        // refreshed for pieces that get written during this run, so we never
        // re-hash already-valid pieces on the web-seed and peer paths below.
        var verifiedPieces = try writer.verifiedPieces()
        let initialDownloaded = bytesCompleted(for: verifiedPieces, metainfo: metainfo)
        try ensureAvailableCapacity(for: metainfo.totalSize - initialDownloaded, at: destination)

        if initialDownloaded >= metainfo.totalSize {
            try writer.finalize()
            await progress(TorrentDownloadProgress(status: "Complete. Existing files verified. No seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
            return
        }

        if !metainfo.webSeedURLs.isEmpty {
            do {
                try await downloadFromWebSeeds(
                    metainfo: metainfo,
                    writer: writer,
                    initialDownloaded: initialDownloaded,
                    progress: progress
                )
                // Web seeds only write pieces we did not already have, so verify
                // just the previously-unverified indices and fold the result in.
                let unverified = Set(metainfo.pieceHashes.indices).subtracting(verifiedPieces)
                verifiedPieces.formUnion(try writer.verifiedPieces(among: unverified))
                let verifiedBytes = bytesCompleted(for: verifiedPieces, metainfo: metainfo)
                if verifiedBytes >= metainfo.totalSize {
                    try writer.finalize()
                    await progress(TorrentDownloadProgress(status: "Complete. Downloaded from web seed. No seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await progress(TorrentDownloadProgress(status: "Web seed failed. Contacting trackers and DHT", downloadedBytes: initialDownloaded, totalBytes: metainfo.totalSize))
            }
        }

        let peerID = Self.makePeerID()
        await progress(TorrentDownloadProgress(status: "Verified existing data. Contacting trackers and DHT", downloadedBytes: initialDownloaded, totalBytes: metainfo.totalSize))
        let peers = try await collectPeers(for: metainfo, peerID: peerID, downloaded: initialDownloaded, left: metainfo.totalSize - initialDownloaded, event: "started")
        do {
            try Task.checkCancellation()
            guard !peers.isEmpty else {
                throw TrackerClientError.invalidResponse
            }

            // Nothing writes to disk between the scan above and here (peer
            // discovery does no I/O), so the cached set is still accurate.
            let verifiedBytes = bytesCompleted(for: verifiedPieces, metainfo: metainfo)
            if verifiedBytes >= metainfo.totalSize {
                try writer.finalize()
                _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: verifiedBytes, left: 0, event: "stopped", includeDHT: false)
                await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
                return
            }

            let downloaded = try await downloadPiecesConcurrently(
                metainfo: metainfo,
                destination: destination,
                peers: Array(peers.shuffled().prefix(maxPeerAttempts)),
                peerID: peerID,
                verifiedPieces: verifiedPieces,
                initialDownloaded: verifiedBytes,
                progress: progress
            )
            try writer.finalize()
            _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: downloaded, left: 0, event: "stopped", includeDHT: false)
            await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
            return
        }
    }

    private func downloadFromWebSeeds(
        metainfo: TorrentMetainfo,
        writer: TorrentFileWriter,
        initialDownloaded: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        var lastError: Error?
        for webSeedURL in metainfo.webSeedURLs {
            try Task.checkCancellation()
            do {
                var downloadedBytes = initialDownloaded
                for file in metainfo.files {
                    try Task.checkCancellation()
                    let sourceURL = webSeedURL.appendingTorrentRelativePath(file.path)
                    await progress(TorrentDownloadProgress(status: "Downloading from web seed: \(file.path)", downloadedBytes: downloadedBytes, totalBytes: metainfo.totalSize))
                    downloadedBytes += try await downloadWebSeedFile(from: sourceURL, file: file, writer: writer, progressDownloadedBytes: downloadedBytes) { currentDownloadedBytes in
                        await progress(TorrentDownloadProgress(status: "Downloading from web seed: \(file.path)", downloadedBytes: currentDownloadedBytes, totalBytes: metainfo.totalSize))
                    }
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
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TrackerClientError.invalidResponse
        }

        let partialURL = try writer.preparePartialFile(for: file)
        let handle = try FileHandle(forWritingTo: partialURL)
        var fileDownloadedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        do {
            defer { try? handle.close() }
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

        guard fileDownloadedBytes == file.length else {
            throw TrackerClientError.invalidResponse
        }
        return fileDownloadedBytes
    }

    private func downloadPiecesConcurrently(
        metainfo: TorrentMetainfo,
        destination: URL,
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
            progress: progress
        )
        guard !sessions.isEmpty else { throw TrackerClientError.invalidResponse }

        let writer = TorrentPieceWriter(writer: TorrentFileWriter(metainfo: metainfo, destination: destination))
        let coordinator = PieceDownloadCoordinator(
            pieceLengths: metainfo.pieceHashes.indices.map { pieceLength(for: $0, metainfo: metainfo) },
            completedPieces: verifiedPieces,
            initialDownloaded: initialDownloaded,
            availabilityCounts: availabilityCounts(from: sessions)
        )

        var lastError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for session in sessions {
                group.addTask {
                    await progress(TorrentDownloadProgress(status: "Connected to peer \(session.endpoint.host):\(session.endpoint.port)", downloadedBytes: initialDownloaded, totalBytes: metainfo.totalSize))
                    while true {
                        try? Task.checkCancellation()
                        guard !Task.isCancelled else { return CancellationError() }
                        // Pull live availability each pass so `have`/`bitfield`
                        // messages received mid-download refine the set. When the
                        // peer never declared availability (unchoked first), fall
                        // back optimistically to all pieces; this self-corrects as
                        // soon as the peer announces anything.
                        let (livePieces, isKnown) = await session.client.currentAvailability()
                        let usablePieces = isKnown ? livePieces : Set(metainfo.pieceHashes.indices)
                        guard let pieceIndex = await coordinator.nextPiece(availablePieces: usablePieces) else {
                            return nil
                        }

                        do {
                            let length = pieceLength(for: pieceIndex, metainfo: metainfo)
                            await progress(TorrentDownloadProgress(status: "Downloading piece \(pieceIndex + 1) of \(metainfo.pieceHashes.count)", downloadedBytes: await coordinator.downloadedBytes, totalBytes: metainfo.totalSize))
                            let piece = try await withTimeout(seconds: .seconds(60)) {
                                try await session.client.downloadPiece(index: pieceIndex, length: length, expectedHash: metainfo.pieceHashes[pieceIndex])
                            }
                            try await writer.write(piece: piece, pieceIndex: pieceIndex)
                            let downloaded = await coordinator.complete(pieceIndex: pieceIndex)
                            await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: downloaded, totalBytes: metainfo.totalSize))
                        } catch is CancellationError {
                            await coordinator.returnPiece(pieceIndex)
                            return CancellationError()
                        } catch {
                            await coordinator.returnPiece(pieceIndex)
                            await progress(TorrentDownloadProgress(status: "Peer \(session.endpoint.host):\(session.endpoint.port) failed piece \(pieceIndex + 1).", downloadedBytes: await coordinator.downloadedBytes, totalBytes: metainfo.totalSize))
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
                        await progress(TorrentDownloadProgress(status: "Connecting to peer \(peer.host):\(peer.port)", downloadedBytes: initialDownloaded, totalBytes: metainfo.totalSize))
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

    private func pieceLength(for index: Int, metainfo: TorrentMetainfo) -> Int {
        if index == metainfo.pieceHashes.count - 1 {
            let consumed = Int64(index * metainfo.pieceLength)
            return Int(metainfo.totalSize - consumed)
        }
        return metainfo.pieceLength
    }

    private func bytesCompleted(for pieces: Set<Int>, metainfo: TorrentMetainfo) -> Int64 {
        pieces.reduce(Int64(0)) { total, pieceIndex in
            total + Int64(pieceLength(for: pieceIndex, metainfo: metainfo))
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
    private let pieceLengths: [Int]
    private let availabilityCounts: [Int: Int]
    private var pendingPieces: Set<Int>
    private var activePieces = Set<Int>()
    private var completedPieces: Set<Int>
    private var completedBytes: Int64

    init(pieceLengths: [Int], completedPieces: Set<Int>, initialDownloaded: Int64, availabilityCounts: [Int: Int]) {
        self.pieceLengths = pieceLengths
        self.completedPieces = completedPieces
        self.completedBytes = initialDownloaded
        self.availabilityCounts = availabilityCounts
        self.pendingPieces = Set(pieceLengths.indices).subtracting(completedPieces)
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

    func complete(pieceIndex: Int) -> Int64 {
        guard activePieces.remove(pieceIndex) != nil, !completedPieces.contains(pieceIndex) else {
            return completedBytes
        }
        completedPieces.insert(pieceIndex)
        completedBytes += Int64(pieceLengths[pieceIndex])
        return completedBytes
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
        for file in metainfo.files {
            let partialURL = try outputURL(for: file, partial: true)
            guard FileManager.default.fileExists(atPath: partialURL.path) else {
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
