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
    private let http: BoundedHTTPClient
    /// Largest exact-source `.torrent` accepted (real ones are a few MB at most).
    private static let maxExactSourceBytes = 32 << 20

    public init(
        trackerClient: TrackerClient = TrackerClient(),
        dhtClient: DHTClient = DHTClient(),
        parser: TorrentMetainfoParser = TorrentMetainfoParser(),
        session: URLSession = .traceless
    ) {
        self.trackerClient = trackerClient
        self.dhtClient = dhtClient
        self.parser = parser
        self.http = BoundedHTTPClient(session: session)
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

        // Peer discovery and metadata fetching run **concurrently**, not in
        // sequence. Discovery used to be a separate phase that had to complete —
        // or hit its deadline — before the first peer was ever dialled, and since
        // the DHT reliably outlives that deadline, every magnet paid the full wait
        // even when a tracker had answered in a second. Now each source feeds the
        // shared cursor the moment it reports (trackers first, DHT peers batch by
        // batch) and the worker pool starts probing whatever has arrived.
        //
        // Nothing is given up to buy that: the DHT still runs its whole query
        // budget and every peer it finds still gets probed, so the set of peers
        // tried is a superset of the old one — the metadata phase just stops
        // sitting idle while it is assembled. That matters because the reach of
        // this phase, not its speed, is what decides whether a magnet resolves at
        // all: metadata-serving seeds are often reachable only via the DHT.
        //
        // Within the pool, most peers in a public swarm are unreachable (NAT) or
        // won't serve metadata, and the few that will are often slow leechers, so
        // probing serially — or giving up after one pass — stalls or fails. The
        // cursor therefore **recycles**: workers keep handshaking peers (a peer
        // that was busy or still fetching metadata itself may serve on a later
        // pass) until one delivers verified metadata or the phase deadline fires.
        // Peers gossiped by the swarm via inbound PEX during these probes are fed
        // back in too, so the phase reaches seeds beyond the tracker/DHT set (the
        // swarm-download path already does this).
        let cursor = PeerCursor(maxPeers: Self.maxMetadataPeers)
        let fetchErrors = ErrorBox()
        let discoveryErrors = ErrorBox()

        let metainfo = try await withThrowingTaskGroup(of: ResolveSignal.self) { group in
            group.addTask {
                await discoverPeers(
                    trackers: trackers,
                    magnet: magnet,
                    peerID: peerID,
                    into: cursor,
                    errors: discoveryErrors,
                    progress: progress
                )
                await cursor.finishDiscovery()
                return .discoveryFinished
            }

            for _ in 0..<Self.maxConcurrentMetadataFetches {
                group.addTask {
                    // `next()` parks the worker while the pool is empty or fully
                    // in flight, so workers spawned before the first tracker
                    // answers wait for peers instead of exiting.
                    while let peer = try await cursor.next() {
                        do {
                            let infoData = try await withTimeout(seconds: .seconds(15)) {
                                try await fetchMetadata(from: peer, magnet: magnet, peerID: peerID) {
                                    // Peer accepted our TCP + BitTorrent handshake, so it is
                                    // reachable — worth retrying. ~3 of 4 swarm peers are NAT'd
                                    // and never get here; concentrating retries on the reachable
                                    // minority is what finds the rare metadata-serving seed.
                                    await cursor.markReachable(peer)
                                } onPeersDiscovered: { discovered in
                                    // Feed PEX-gossiped peers back into the pool so the metadata
                                    // phase expands beyond the initial tracker/DHT set.
                                    await cursor.add(discovered)
                                }
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
                            await cursor.release(peer)
                            return .resolved(metainfo)
                        } catch is CancellationError {
                            await cursor.release(peer)
                            throw CancellationError()
                        } catch {
                            await cursor.release(peer)
                            await fetchErrors.record(error)
                        }
                    }
                    return .workerFinished
                }
            }

            // Deadline sentinel bounding the whole phase, so a dead swarm errors in
            // seconds-to-a-minute instead of hanging while a live-but-slow seed
            // still gets found.
            group.addTask {
                try? await Task.sleep(for: Self.metadataPhaseDeadline)
                return .deadline
            }

            var resolved: TorrentMetainfo?
            var liveWorkers = Self.maxConcurrentMetadataFetches
            consume: for try await signal in group {
                switch signal {
                case let .resolved(metainfo):
                    resolved = metainfo
                    break consume
                case .deadline:
                    break consume
                case .discoveryFinished:
                    // Sources are done, but peers already found are still being
                    // probed (and may still gossip more via PEX) — keep going.
                    continue
                case .workerFinished:
                    // A worker only runs out of peers when the cursor is empty and
                    // discovery is over, i.e. nothing was ever found. Once every
                    // worker has hit that, there is nothing left to wait for.
                    liveWorkers -= 1
                    if liveWorkers == 0 { break consume }
                }
            }
            group.cancelAll()
            return resolved
        }

        if let metainfo {
            await progress(MagnetMetadataProgress(status: "Metadata resolved: \(metainfo.name)"))
            return metainfo
        }

        // No peer ever reached the cursor means the failure was in discovery, so
        // surface the tracker/DHT error rather than a stale fetch error.
        if await cursor.count == 0 {
            throw await discoveryErrors.lastError ?? MagnetMetadataResolverError.noPeers
        }
        throw await fetchErrors.lastError ?? MagnetMetadataResolverError.noPeers
    }

    /// What a child of the resolve task group reports back.
    private enum ResolveSignal: Sendable {
        case resolved(TorrentMetainfo)
        case discoveryFinished
        case workerFinished
        case deadline
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
                let (data, httpResponse) = try await http.data(for: request, limit: Self.maxExactSourceBytes)
                guard (200..<300).contains(httpResponse.statusCode) else {
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

    /// Runs every peer source concurrently, pushing endpoints into `cursor` as
    /// soon as each one reports rather than returning a single batch at the end.
    /// Returns once all sources are done, the cursor is full, or the discovery
    /// deadline fires; stragglers are cancelled on exit.
    private func discoverPeers(
        trackers: [URL],
        magnet: MagnetLink,
        peerID: Data,
        into cursor: PeerCursor,
        errors: ErrorBox,
        progress: @Sendable @escaping (MagnetMetadataProgress) async -> Void
    ) async {
        await withTaskGroup(of: DiscoverySignal.self) { group in
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
                        await cursor.add(try await trackerClient.announce(request))
                        return .source(nil)
                    } catch {
                        return .source(error)
                    }
                }
            }
            group.addTask {
                do {
                    try Task.checkCancellation()
                    // Stream the DHT's peers batch by batch instead of waiting on
                    // its whole query budget: on a trackerless magnet these are the
                    // only peers there are, and the first batch lands many seconds
                    // before the last.
                    _ = try await dhtClient.peers(for: magnet.infoHash) { found in
                        await cursor.add(found)
                    }
                    return .source(nil)
                } catch {
                    return .source(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.peerDiscoveryDeadline)
                return .deadline
            }

            let realSources = trackers.count + 1 // trackers + DHT
            var reported = 0
            collect: for await signal in group {
                if Task.isCancelled { break collect }
                switch signal {
                case .deadline:
                    break collect
                case let .source(error):
                    reported += 1
                    if let error { await errors.record(error) }
                    let count = await cursor.count
                    if count > 0 {
                        await progress(MagnetMetadataProgress(
                            status: "Fetching magnet metadata from \(count) peers"
                        ))
                    }
                    if reported >= realSources { break collect }
                    if await cursor.isFull { break collect }
                }
            }
            group.cancelAll()
        }
    }

    /// A discovery source finishing (carrying its error, if it failed), or the
    /// discovery deadline firing.
    private enum DiscoverySignal: Sendable {
        case source(Error?)
        case deadline
    }

    /// Hard stop on peer discovery even if a tracker or the DHT is still working.
    /// Generous on purpose, and much longer than it used to be: discovery no
    /// longer delays the first probe, so letting the DHT finish its query budget
    /// costs nothing and only widens the pool a stubborn magnet gets to draw on.
    /// It stays well inside `metadataPhaseDeadline`, which bounds the phase overall.
    private static let peerDiscoveryDeadline: Duration = .seconds(60)

    private func fetchMetadata(
        from peer: PeerEndpoint,
        magnet: MagnetLink,
        peerID: Data,
        onConnected: @Sendable () async -> Void = {},
        onPeersDiscovered: @Sendable ([PeerEndpoint]) async -> Void = { _ in }
    ) async throws -> Data {
        // A short connect timeout is what keeps a worker slot from being pinned
        // for 10s by an unreachable (NAT/filtered) peer; a peer that actually has
        // metadata completes its handshake within a couple seconds.
        let client = PeerWireClient(endpoint: peer, infoHash: magnet.infoHash, peerID: peerID, connectTimeout: 8)
        do {
            try await client.connect()
            await onConnected()
            let metadata = try await client.fetchMetadata()
            // Harvest any peers this connection gossiped via PEX. Even a leecher
            // that couldn't serve metadata (the failure path below) may have
            // pointed us at a seed that can.
            await onPeersDiscovered(await client.takeDiscoveredPeers())
            await client.close()
            return metadata
        } catch {
            await onPeersDiscovered(await client.takeDiscoveredPeers())
            await client.close()
            throw error
        }
    }
}

/// Hands out swarm peers to a pool of concurrent metadata-fetch workers, learning
/// reachability as it goes.
///
/// Peers **stream in** while workers are already probing: trackers and the DHT
/// call `add` as they report, and inbound PEX gossip folds in the same way, so
/// the pool keeps widening throughout the phase rather than being fixed up front.
///
/// **Untried peers first:** anything never probed is handed out before anything
/// is retried — a fresh peer is at least as likely to be the metadata seed as a
/// re-dial. **Then recycling:** once nothing untried is left it cycles the peers
/// that actually connected, since re-dialing the ~75% NAT'd majority just burns
/// the phase budget on connect timeouts. Concentrating retries on reachable peers
/// is what lets the rare metadata-serving seed be hit repeatedly until it
/// delivers. A peer is never handed to two workers at once, so a pool smaller
/// than the worker count can't be dogpiled.
///
/// `next()` parks the caller while the pool is empty or fully in flight, and
/// returns nil only when discovery is over and there is genuinely nothing left —
/// i.e. no peer was ever found.
actor PeerCursor {
    /// Every endpoint ever accepted, in arrival order. Doubles as the fallback
    /// recycling pool before any peer has proved reachable.
    private var all: [PeerEndpoint] = []
    /// Endpoints not yet handed to a worker.
    private var untried: [PeerEndpoint] = []
    private var untriedIndex = 0
    private var reachable: [PeerEndpoint] = []
    private var reachableSeen = Set<PeerEndpoint>()
    private var recycleIndex = 0
    /// Every endpoint ever queued, so a peer reported by two sources — or
    /// gossiped twice — is not queued again.
    private var seen = Set<PeerEndpoint>()
    /// Peers currently being probed, so no two workers dial the same one.
    private var inFlight = Set<PeerEndpoint>()
    private var discoveryFinished = false
    private let maxPeers: Int

    init(maxPeers: Int) {
        self.maxPeers = maxPeers
    }

    var count: Int { all.count }
    var isFull: Bool { all.count >= maxPeers }

    /// Records that a peer accepted our handshake, so later passes retry it.
    func markReachable(_ peer: PeerEndpoint) {
        if reachableSeen.insert(peer).inserted {
            reachable.append(peer)
        }
    }

    /// Queues peers from a tracker, the DHT, or inbound PEX gossip, deduped
    /// against everything already seen and capped so one huge swarm can't grow
    /// the pool without bound. Download-only: gossiped peers come from consuming
    /// the swarm's `added` list, never from advertising ourselves.
    func add(_ peers: [PeerEndpoint]) {
        for peer in peers {
            guard all.count < maxPeers else { return }
            guard seen.insert(peer).inserted else { continue }
            all.append(peer)
            untried.append(peer)
        }
    }

    /// Marks discovery complete, so workers can tell "no peers yet" from "no
    /// peers at all".
    func finishDiscovery() {
        discoveryFinished = true
    }

    /// Returns a peer to the pool once its probe finishes, making it eligible for
    /// a later retry.
    func release(_ peer: PeerEndpoint) {
        inFlight.remove(peer)
    }

    func next() async throws -> PeerEndpoint? {
        while true {
            try Task.checkCancellation()
            if let peer = takeAvailable() { return peer }
            // Nothing to hand out: either discovery hasn't produced peers yet, or
            // every known peer is already being probed. Both are temporary unless
            // discovery is done and the pool is empty.
            if discoveryFinished, all.isEmpty { return nil }
            // Polling rather than parking on a continuation keeps this
            // cancellation-correct without a resume-once guard; at probe
            // timescales (seconds) the wait granularity is free.
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func takeAvailable() -> PeerEndpoint? {
        while untriedIndex < untried.count {
            let peer = untried[untriedIndex]
            untriedIndex += 1
            if inFlight.insert(peer).inserted { return peer }
        }
        // Retry only reachable peers. Until any are known (in-flight probes
        // haven't reported yet), fall back to recycling everything so workers
        // never starve mid-sweep.
        let pool = reachable.isEmpty ? all : reachable
        guard !pool.isEmpty else { return nil }
        for _ in 0..<pool.count {
            if recycleIndex >= pool.count { recycleIndex = 0 }
            let peer = pool[recycleIndex]
            recycleIndex = (recycleIndex + 1) % pool.count
            if inFlight.insert(peer).inserted { return peer }
        }
        return nil // every candidate is already in flight
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
    try await withDeadline(seconds, timeoutError: TimeoutError.timedOut, operation: operation)
}
