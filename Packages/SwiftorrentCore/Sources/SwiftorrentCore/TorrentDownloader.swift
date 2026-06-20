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

    public init(trackerClient: TrackerClient = TrackerClient()) {
        self.trackerClient = trackerClient
    }

    public func download(
        metainfo: TorrentMetainfo,
        destination: URL,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ensureAvailableCapacity(for: metainfo.totalSize, at: destination)

        let peerID = Self.makePeerID()
        await progress(TorrentDownloadProgress(status: "Contacting trackers", downloadedBytes: 0, totalBytes: metainfo.totalSize))
        let peers = try await collectPeers(for: metainfo, peerID: peerID, event: "started")
        guard let firstPeer = peers.first else {
            throw TrackerClientError.invalidResponse
        }

        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let client = PeerWireClient(endpoint: firstPeer, infoHash: metainfo.infoHash, peerID: peerID)
        defer { Task { await client.close() } }

        try await client.connect()
        var downloaded: Int64 = 0

        for pieceIndex in metainfo.pieceHashes.indices {
            let pieceLength = pieceLength(for: pieceIndex, metainfo: metainfo)
            await progress(TorrentDownloadProgress(status: "Downloading piece \(pieceIndex + 1) of \(metainfo.pieceHashes.count)", downloadedBytes: downloaded, totalBytes: metainfo.totalSize))
            let piece = try await client.downloadPiece(index: pieceIndex, length: pieceLength, expectedHash: metainfo.pieceHashes[pieceIndex])
            try writer.write(piece: piece, pieceIndex: pieceIndex)
            downloaded += Int64(piece.count)
            await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: downloaded, totalBytes: metainfo.totalSize))
        }

        _ = try? await collectPeers(for: metainfo, peerID: peerID, downloaded: downloaded, left: 0, event: "stopped")
        await progress(TorrentDownloadProgress(status: "Complete. Stopped without seeding.", downloadedBytes: metainfo.totalSize, totalBytes: metainfo.totalSize))
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
        return Array(peers)
    }

    private func pieceLength(for index: Int, metainfo: TorrentMetainfo) -> Int {
        if index == metainfo.pieceHashes.count - 1 {
            let consumed = Int64(index * metainfo.pieceLength)
            return Int(metainfo.totalSize - consumed)
        }
        return metainfo.pieceLength
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
            let chunk = Data(remaining[sourceOffset..<(sourceOffset + count)])
            try write(chunk: chunk, to: file, at: localStart - fileStart)
            remaining.removeFirst(sourceOffset + count)
            offsetInTorrent = localEnd
            if remaining.isEmpty { break }
        }
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
}
