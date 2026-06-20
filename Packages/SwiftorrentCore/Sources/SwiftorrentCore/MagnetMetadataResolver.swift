import CryptoKit
import Foundation

public struct MagnetMetadataProgress: Sendable {
    public let status: String

    public init(status: String) {
        self.status = status
    }
}

public enum MagnetMetadataResolverError: Error, LocalizedError {
    case noSupportedTrackers
    case noPeers
    case metadataHashMismatch

    public var errorDescription: String? {
        switch self {
        case .noSupportedTrackers: "No supported trackers are available for this magnet link yet."
        case .noPeers: "Trackers did not return any usable peers."
        case .metadataHashMismatch: "Downloaded magnet metadata did not match the magnet info hash."
        }
    }
}

public struct MagnetMetadataResolver: Sendable {
    private let trackerClient: TrackerClient
    private let parser: TorrentMetainfoParser

    public init(trackerClient: TrackerClient = TrackerClient(), parser: TorrentMetainfoParser = TorrentMetainfoParser()) {
        self.trackerClient = trackerClient
        self.parser = parser
    }

    public func resolve(
        magnet: MagnetLink,
        progress: @Sendable @escaping (MagnetMetadataProgress) async -> Void
    ) async throws -> TorrentMetainfo {
        let trackers = magnet.trackers.filter { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https" || scheme == "udp"
        }
        guard !trackers.isEmpty else { throw MagnetMetadataResolverError.noSupportedTrackers }

        let peerID = TorrentDownloader.makePeerID()
        await progress(MagnetMetadataProgress(status: "Contacting \(trackers.count) trackers for magnet peers"))
        let peers = try await collectPeers(trackers: trackers, magnet: magnet, peerID: peerID)
        guard !peers.isEmpty else { throw MagnetMetadataResolverError.noPeers }

        await progress(MagnetMetadataProgress(status: "Fetching magnet metadata from \(peers.count) peers"))
        var lastError: Error?

        for peer in peers.prefix(24) {
            do {
                let infoData = try await withTimeout(seconds: .seconds(20)) {
                    try await fetchMetadata(from: peer, magnet: magnet, peerID: peerID)
                }
                let hash = Data(Insecure.SHA1.hash(data: infoData))
                guard hash == magnet.infoHash else {
                    throw MagnetMetadataResolverError.metadataHashMismatch
                }
                let metainfo = try parser.parseInfoDictionary(
                    data: infoData,
                    announceURLs: trackers,
                    preferredName: magnet.displayName
                )
                await progress(MagnetMetadataProgress(status: "Metadata resolved: \(metainfo.name)"))
                return metainfo
            } catch {
                lastError = error
            }
        }

        throw lastError ?? MagnetMetadataResolverError.noPeers
    }

    private func collectPeers(trackers: [URL], magnet: MagnetLink, peerID: Data) async throws -> [PeerEndpoint] {
        var peers: Set<PeerEndpoint> = []
        var lastError: Error?

        await withTaskGroup(of: Result<[PeerEndpoint], Error>.self) { group in
            for tracker in trackers {
                group.addTask {
                    do {
                        let request = TrackerRequest(
                            announceURL: tracker,
                            infoHash: magnet.infoHash,
                            peerID: peerID,
                            downloaded: 0,
                            left: Int64.max,
                            event: "started"
                        )
                        return .success(try await trackerClient.announce(request))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                switch result {
                case let .success(endpoints):
                    peers.formUnion(endpoints)
                case let .failure(error):
                    lastError = error
                }
            }
        }

        if peers.isEmpty, let lastError {
            throw lastError
        }
        return Array(peers).shuffled()
    }

    private func fetchMetadata(from peer: PeerEndpoint, magnet: MagnetLink, peerID: Data) async throws -> Data {
        let client = PeerWireClient(endpoint: peer, infoHash: magnet.infoHash, peerID: peerID)
        defer { Task { await client.close() } }
        try await client.connect()
        return try await client.fetchMetadata()
    }
}

public func withTimeout<T: Sendable>(
    seconds: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: seconds)
            throw CancellationError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
