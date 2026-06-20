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
    case exactSourceInvalid

    public var errorDescription: String? {
        switch self {
        case .noSupportedTrackers: "No supported trackers or DHT bootstrap nodes are available for this magnet link yet."
        case .noPeers: "Trackers did not return any usable peers."
        case .metadataHashMismatch: "Downloaded magnet metadata did not match the magnet info hash."
        case .exactSourceInvalid: "The exact-source torrent did not match the magnet info hash."
        }
    }
}

public struct MagnetMetadataResolver: Sendable {
    private let trackerClient: TrackerClient
    private let dhtClient: DHTClient
    private let parser: TorrentMetainfoParser
    private let session: URLSession

    public init(
        trackerClient: TrackerClient = TrackerClient(),
        dhtClient: DHTClient = DHTClient(),
        parser: TorrentMetainfoParser = TorrentMetainfoParser(),
        session: URLSession = .shared
    ) {
        self.trackerClient = trackerClient
        self.dhtClient = dhtClient
        self.parser = parser
        self.session = session
    }

    public func resolve(
        magnet: MagnetLink,
        progress: @Sendable @escaping (MagnetMetadataProgress) async -> Void
    ) async throws -> TorrentMetainfo {
        try Task.checkCancellation()
        if let metainfo = try await resolveFromExactSources(magnet: magnet, progress: progress) {
            return metainfo
        }

        let trackers = magnet.trackers.filter { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https" || scheme == "udp"
        }

        let peerID = TorrentDownloader.makePeerID()
        let sourceDescription = trackers.isEmpty ? "DHT" : "\(trackers.count) trackers and DHT"
        await progress(MagnetMetadataProgress(status: "Contacting \(sourceDescription) for magnet peers"))
        let peers = try await collectPeers(trackers: trackers, magnet: magnet, peerID: peerID)
        guard !peers.isEmpty else { throw MagnetMetadataResolverError.noPeers }

        await progress(MagnetMetadataProgress(status: "Fetching magnet metadata from \(peers.count) peers"))
        var lastError: Error?

        for peer in peers.prefix(24) {
            try Task.checkCancellation()
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
                    webSeedURLs: magnet.webSeeds,
                    preferredName: magnet.displayName
                )
                await progress(MagnetMetadataProgress(status: "Metadata resolved: \(metainfo.name)"))
                return metainfo
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        throw lastError ?? MagnetMetadataResolverError.noPeers
    }

    private func resolveFromExactSources(
        magnet: MagnetLink,
        progress: @Sendable @escaping (MagnetMetadataProgress) async -> Void
    ) async throws -> TorrentMetainfo? {
        var lastError: Error?
        for source in magnet.exactSources {
            try Task.checkCancellation()
            do {
                await progress(MagnetMetadataProgress(status: "Fetching metadata from exact source"))
                var request = URLRequest(url: source)
                request.timeoutInterval = 20
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw MagnetMetadataResolverError.exactSourceInvalid
                }
                let metainfo = try parser.parse(data: data).adding(
                    announceURLs: magnet.trackers,
                    webSeedURLs: magnet.webSeeds
                )
                guard metainfo.infoHash == magnet.infoHash else {
                    throw MagnetMetadataResolverError.exactSourceInvalid
                }
                await progress(MagnetMetadataProgress(status: "Metadata resolved: \(metainfo.name)"))
                return metainfo
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if !magnet.exactSources.isEmpty, magnet.trackers.isEmpty {
            throw lastError ?? MagnetMetadataResolverError.exactSourceInvalid
        }
        return nil
    }

    private func collectPeers(trackers: [URL], magnet: MagnetLink, peerID: Data) async throws -> [PeerEndpoint] {
        var peers: Set<PeerEndpoint> = []
        var lastError: Error?

        await withTaskGroup(of: Result<[PeerEndpoint], Error>.self) { group in
            for tracker in trackers {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let request = TrackerRequest(
                            announceURL: tracker,
                            infoHash: magnet.infoHash,
                            peerID: peerID,
                            downloaded: 0,
                            left: 0,
                            event: "started"
                        )
                        return .success(try await trackerClient.announce(request))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            group.addTask {
                do {
                    try Task.checkCancellation()
                    return .success(try await dhtClient.peers(for: magnet.infoHash))
                } catch {
                    return .failure(error)
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

    private func fetchMetadata(from peer: PeerEndpoint, magnet: MagnetLink, peerID: Data) async throws -> Data {
        let client = PeerWireClient(endpoint: peer, infoHash: magnet.infoHash, peerID: peerID)
        do {
            try await client.connect()
            let metadata = try await client.fetchMetadata()
            await client.close()
            return metadata
        } catch {
            await client.close()
            throw error
        }
    }
}

public enum TimeoutError: Error, LocalizedError {
    case timedOut

    public var errorDescription: String? {
        "The network operation timed out."
    }
}

public func withTimeout<T: Sendable>(
    seconds: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try Task.checkCancellation()
            return try await operation()
        }
        group.addTask {
            try await Task.sleep(for: seconds)
            throw TimeoutError.timedOut
        }
        guard let result = try await group.next() else {
            throw TimeoutError.timedOut
        }
        group.cancelAll()
        return result
    }
}
