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

        // Try peers concurrently. Most peers in a public swarm are unreachable
        // (NAT) or won't serve metadata, and the few that will are often slow
        // leechers, so probing serially — or giving up after one pass — stalls or
        // fails. A bounded worker pool pulls from a **recycling** cursor: workers
        // keep handshaking peers (retrying the pool, since a peer that was busy or
        // still fetching metadata itself may serve on a later pass) until one
        // delivers verified metadata or the overall deadline fires. The deadline
        // bounds the whole phase so a dead swarm errors in seconds-to-a-minute
        // instead of hanging, while a live-but-slow seed still gets found.
        await progress(MagnetMetadataProgress(status: "Fetching magnet metadata from \(peers.count) peers"))
        let candidates = Array(peers.prefix(Self.maxMetadataPeers))
        let cursor = PeerCursor(peers: candidates)
        let errorBox = ErrorBox()
        let workerCount = min(Self.maxConcurrentMetadataFetches, candidates.count)

        let metainfo = try await withThrowingTaskGroup(of: TorrentMetainfo?.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while let peer = await cursor.next() {
                        try Task.checkCancellation()
                        do {
                            let infoData = try await withTimeout(seconds: .seconds(15)) {
                                try await fetchMetadata(from: peer, magnet: magnet, peerID: peerID) {
                                    // Peer accepted our TCP + BitTorrent handshake, so it is
                                    // reachable — worth retrying. ~3 of 4 swarm peers are NAT'd
                                    // and never get here; concentrating retries on the reachable
                                    // minority is what finds the rare metadata-serving seed.
                                    await cursor.markReachable(peer)
                                }
                            }
                            let hash = Data(Insecure.SHA1.hash(data: infoData))
                            guard hash == magnet.infoHash else {
                                throw MagnetMetadataResolverError.metadataHashMismatch
                            }
                            return try parser.parseInfoDictionary(
                                data: infoData,
                                announceURLs: trackers,
                                webSeedURLs: magnet.webSeeds,
                                preferredName: magnet.displayName
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await errorBox.record(error)
                        }
                    }
                    return nil // recycling cursor only returns nil once cancelled
                }
            }
            // Deadline sentinel: returns nil to end the phase if no worker has
            // succeeded by the time it fires.
            group.addTask {
                try? await Task.sleep(for: Self.metadataPhaseDeadline)
                return nil
            }

            var resolved: TorrentMetainfo?
            for try await result in group {
                if let result {
                    resolved = result
                    break
                }
                // A nil is either the deadline firing or a worker seeing a
                // cancelled cursor; both mean we should stop.
                break
            }
            group.cancelAll()
            return resolved
        }

        if let metainfo {
            await progress(MagnetMetadataProgress(status: "Metadata resolved: \(metainfo.name)"))
            return metainfo
        }

        throw await errorBox.lastError ?? MagnetMetadataResolverError.noPeers
    }

    /// Upper bound on peers probed for metadata per magnet, how many probes run
    /// at once, and the wall-clock budget for the whole metadata phase. Trying a
    /// wide slice of the swarm concurrently — and retrying it until the deadline —
    /// is what keeps a magnet from stalling behind unreachable/slow peers while
    /// still finding the occasional slow seed that actually has the metadata.
    private static let maxMetadataPeers = 300
    private static let maxConcurrentMetadataFetches = 24
    private static let metadataPhaseDeadline: Duration = .seconds(90)

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

        // Each source (tracker or DHT) returns `.some(result)`; a deadline task
        // returns `nil`. We stop as soon as we have enough peers to start
        // fetching metadata, or the deadline fires — otherwise a fast tracker's
        // peers would sit unused for minutes while the DHT exhausts its query
        // budget (the whole group would only return once its *slowest* source
        // finished). Stragglers are cancelled on exit.
        await withTaskGroup(of: Optional<Result<[PeerEndpoint], Error>>.self) { group in
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
            group.addTask {
                try? await Task.sleep(for: Self.peerCollectionDeadline)
                return nil
            }

            for await result in group {
                if Task.isCancelled { break }
                guard let result else { break } // deadline reached
                switch result {
                case let .success(endpoints):
                    peers.formUnion(endpoints)
                case let .failure(error):
                    lastError = error
                }
                if peers.count >= Self.enoughPeersToStart { break }
            }
            group.cancelAll()
        }

        try Task.checkCancellation()
        if peers.isEmpty, let lastError {
            throw lastError
        }
        return Array(peers).shuffled()
    }

    /// Peer-collection stops early once this many peers are gathered, and never
    /// runs longer than the deadline even if a slow DHT/tracker is still working.
    /// The threshold is deliberately high: metadata-serving seeds are often
    /// reachable only via the DHT or a specific tracker, so quitting the instant
    /// one fast tracker answers (with mostly unreachable leechers) tanks the
    /// odds of the metadata phase succeeding. We'd rather spend a few extra
    /// seconds gathering a diverse set from every source.
    private static let enoughPeersToStart = 300
    private static let peerCollectionDeadline: Duration = .seconds(18)

    private func fetchMetadata(
        from peer: PeerEndpoint,
        magnet: MagnetLink,
        peerID: Data,
        onConnected: @Sendable () async -> Void = {}
    ) async throws -> Data {
        // A short connect timeout is what keeps a worker slot from being pinned
        // for 10s by an unreachable (NAT/filtered) peer; a peer that actually has
        // metadata completes its handshake within a couple seconds.
        let client = PeerWireClient(endpoint: peer, infoHash: magnet.infoHash, peerID: peerID, connectTimeout: 8)
        do {
            try await client.connect()
            await onConnected()
            let metadata = try await client.fetchMetadata()
            await client.close()
            return metadata
        } catch {
            await client.close()
            throw error
        }
    }
}

/// Hands out swarm peers to a pool of concurrent metadata-fetch workers, learning
/// reachability as it goes. **First pass:** every candidate is tried once (broad
/// sweep to discover which peers actually accept a connection — roughly 1 in 4,
/// the rest being NAT'd and dropping our SYN). **After the first pass:** it cycles
/// only the peers that connected, since re-dialing the ~75% unreachable majority
/// just burns the metadata-phase budget on connect timeouts. Concentrating
/// retries on reachable peers is what lets the rare metadata-serving seed be hit
/// repeatedly until it delivers. Returns nil only when the peer list is empty.
private actor PeerCursor {
    private let all: [PeerEndpoint]
    private var index = 0
    private var firstPassComplete = false
    private var reachable: [PeerEndpoint] = []
    private var reachableSeen = Set<PeerEndpoint>()
    private var reachableIndex = 0

    init(peers: [PeerEndpoint]) {
        all = peers
    }

    /// Records that a peer accepted our handshake, so later passes retry it.
    func markReachable(_ peer: PeerEndpoint) {
        if reachableSeen.insert(peer).inserted {
            reachable.append(peer)
        }
    }

    func next() -> PeerEndpoint? {
        guard !all.isEmpty else { return nil }
        if !firstPassComplete {
            if index < all.count {
                defer { index += 1 }
                return all[index]
            }
            firstPassComplete = true
        }
        // Retry only reachable peers. Until any are known (in-flight first-pass
        // probes haven't reported yet), fall back to recycling the full list so
        // workers never starve mid-sweep.
        let pool = reachable.isEmpty ? all : reachable
        if reachableIndex >= pool.count { reachableIndex = 0 }
        defer { reachableIndex = (reachableIndex + 1) % pool.count }
        return pool[reachableIndex]
    }
}

/// Collects the most recent non-cancellation failure across concurrent metadata
/// workers so the resolver can surface a meaningful error if no peer succeeds.
private actor ErrorBox {
    private(set) var lastError: Error?

    func record(_ error: Error) {
        lastError = error
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
