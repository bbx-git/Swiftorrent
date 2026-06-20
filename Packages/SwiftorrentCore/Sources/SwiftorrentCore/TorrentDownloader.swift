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
    private let trackerClient: TrackerClient
    private let maxPeerAttempts = 24

    public init(trackerClient: TrackerClient = TrackerClient()) {
        self.trackerClient = trackerClient
    }

    public func download(
        metainfo: TorrentMetainfo,
        destination: URL,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let initialVerifiedPieces = try writer.verifiedPieces()
        let initialDownloaded = bytesCompleted(for: initialVerifiedPieces, metainfo: metainfo)
        try ensureAvailableCapacity(for: metainfo.totalSize - initialDownloaded, at: destination)

        if initialDownloaded >= metainfo.totalSize {
            await progress(TorrentDownloadProgress(status: "Complete. Existing files verified. No seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
            return
        }

        let peerID = Self.makePeerID()
        await progress(TorrentDownloadProgress(status: "Verified existing data. Contacting trackers", downloadedBytes: initialDownloaded, totalBytes: metainfo.totalSize))
        let peers = try await collectPeers(for: metainfo, peerID: peerID, downloaded: initialDownloaded, left: metainfo.totalSize - initialDownloaded, event: "started")
        do {
            try Task.checkCancellation()
            guard !peers.isEmpty else {
                throw TrackerClientError.invalidResponse
            }

            var lastError: Error?
            for peer in peers.shuffled().prefix(maxPeerAttempts) {
                try Task.checkCancellation()
                let verifiedPieces = try writer.verifiedPieces()
                let verifiedBytes = bytesCompleted(for: verifiedPieces, metainfo: metainfo)
                if verifiedBytes >= metainfo.totalSize {
                    _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: verifiedBytes, left: 0, event: "stopped")
                    await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
                    return
                }
                do {
                    let downloaded = try await downloadAllPieces(
                        metainfo: metainfo,
                        destination: destination,
                        peer: peer,
                        peerID: peerID,
                        verifiedPieces: verifiedPieces,
                        initialDownloaded: verifiedBytes,
                        progress: progress
                    )
                    _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: downloaded, left: 0, event: "stopped")
                    await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    let recoveredBytes = bytesCompleted(for: (try? writer.verifiedPieces()) ?? [], metainfo: metainfo)
                    await progress(TorrentDownloadProgress(status: "Peer \(peer.host):\(peer.port) failed. Trying another peer.", downloadedBytes: recoveredBytes, totalBytes: metainfo.totalSize))
                }
            }

            throw lastError ?? TrackerClientError.invalidResponse
        }
    }

    private func downloadAllPieces(
        metainfo: TorrentMetainfo,
        destination: URL,
        peer: PeerEndpoint,
        peerID: Data,
        verifiedPieces: Set<Int>,
        initialDownloaded: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws -> Int64 {
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let client = PeerWireClient(endpoint: peer, infoHash: metainfo.infoHash, peerID: peerID)
        defer { Task { await client.close() } }

        await progress(TorrentDownloadProgress(status: "Connecting to peer \(peer.host):\(peer.port)", downloadedBytes: 0, totalBytes: metainfo.totalSize))
        try Task.checkCancellation()
        try await withTimeout(seconds: .seconds(20)) {
            try await client.connect()
        }

        var downloaded = initialDownloaded
        for pieceIndex in metainfo.pieceHashes.indices {
            try Task.checkCancellation()
            let pieceLength = pieceLength(for: pieceIndex, metainfo: metainfo)
            if verifiedPieces.contains(pieceIndex) {
                await progress(TorrentDownloadProgress(status: "Resuming. Skipping verified piece \(pieceIndex + 1) of \(metainfo.pieceHashes.count)", downloadedBytes: downloaded, totalBytes: metainfo.totalSize))
                continue
            }
            await progress(TorrentDownloadProgress(status: "Downloading piece \(pieceIndex + 1) of \(metainfo.pieceHashes.count)", downloadedBytes: downloaded, totalBytes: metainfo.totalSize))
            let piece = try await withTimeout(seconds: .seconds(60)) {
                try await client.downloadPiece(index: pieceIndex, length: pieceLength, expectedHash: metainfo.pieceHashes[pieceIndex])
            }
            try writer.write(piece: piece, pieceIndex: pieceIndex)
            downloaded += Int64(piece.count)
            await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: downloaded, totalBytes: metainfo.totalSize))
        }

        return downloaded
    }

    private func collectPeers(
        for metainfo: TorrentMetainfo,
        peerID: Data,
        downloaded: Int64 = 0,
        left: Int64? = nil,
        event: String?
    ) async throws -> [PeerEndpoint] {
        var peers: Set<PeerEndpoint> = []
        var lastError: Error?

        for url in metainfo.announceURLs {
            try Task.checkCancellation()
            do {
                let request = TrackerRequest(
                    announceURL: url,
                    infoHash: metainfo.infoHash,
                    peerID: peerID,
                    downloaded: downloaded,
                    left: left ?? metainfo.totalSize,
                    event: event
                )
                peers.formUnion(try await trackerClient.announce(request))
            } catch {
                lastError = error
            }
        }

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
        return "-SW0001-\(suffix)0000".prefix(20).data(using: .ascii)!
    }
}

struct TorrentFileWriter: Sendable {
    let metainfo: TorrentMetainfo
    let destination: URL

    func verifiedPieces() throws -> Set<Int> {
        var verified = Set<Int>()
        for pieceIndex in metainfo.pieceHashes.indices {
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
        let url = destination.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: chunk)
    }

    private func readChunk(from file: TorrentFile, at offset: Int64, count: Int) throws -> Data? {
        let url = destination.appendingPathComponent(file.path)
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
}
