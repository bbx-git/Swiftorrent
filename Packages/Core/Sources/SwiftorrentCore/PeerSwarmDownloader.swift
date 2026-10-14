import Foundation

/// Downloads pieces from a swarm of peers over the peer-wire protocol. Runs a
/// bounded pool of `maxPeerConnections` worker tasks; each worker pulls a fresh
/// peer from a shared `PeerSupply` reserve, connects, and repeatedly downloads
/// the rarest needed piece from a shared `PieceDownloadCoordinator`, writing each
/// verified piece to disk. When a peer fails or runs out of useful pieces the
/// worker closes it and draws a **replacement** peer from the reserve, so the
/// swarm keeps refilling toward `maxPeerConnections` active connections instead
/// of bleeding out as peers die.
///
/// A supervisor task keeps the reserve alive so the download can't fail merely
/// because the initial peer snapshot was exhausted: it periodically re-announces
/// (via `refillPeers`) to fold fresh tracker/DHT peers in — on top of the inbound
/// PEX peers workers already contribute — and only ends the run once every piece
/// is present, the swarm goes quiet past `stallDeadline`, or the task is
/// cancelled. Download-only peers (which never unchoke a non-uploading client)
/// mean we must keep reaching new seeds rather than giving up on the first slice.
/// Returns the total downloaded byte count once every selectable piece is present.
struct PeerSwarmDownloader: Sendable {
    let maxPeerConnections: Int
    var rateLimiter: RateLimiter? = nil

    /// How often the supervisor re-announces to trackers/DHT to refill the reserve.
    private static let reannounceInterval: Duration = .seconds(45)
    /// The download is abandoned only after this long with **no** byte progress at
    /// all (completed or in-flight). Generous on purpose: a temporary lull where
    /// every reachable peer is choking us must not kill an otherwise live transfer.
    private static let stallDeadline: Duration = .seconds(300)

    func download(
        metainfo: TorrentMetainfo,
        destination: URL,
        layout: TorrentLayout,
        selectablePieces: Set<Int>,
        mapper: FileProgressMapper,
        downloadTotal: Int64,
        peers: [PeerEndpoint],
        peerID: Data,
        verifiedPieces: Set<Int>,
        initialDownloaded: Int64,
        stripRootDirectory: Bool,
        refillPeers: @Sendable @escaping () async -> [PeerEndpoint] = { [] },
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws -> Int64 {
        guard !peers.isEmpty else { throw TrackerClientError.invalidResponse }

        let writer = TorrentPieceWriter(writer: TorrentFileWriter(metainfo: metainfo, destination: destination, stripRootDirectory: stripRootDirectory))
        let coordinator = PieceDownloadCoordinator(
            layout: layout,
            selectablePieces: selectablePieces,
            completedPieces: verifiedPieces,
            initialDownloaded: initialDownloaded,
            // Counts start empty; each worker folds its peer's availability in via
            // `addAvailability` as the swarm is assembled and replenished.
            availabilityCounts: [:]
        )
        let supply = PeerSupply(peers: peers)

        let context = WorkerContext(
            metainfo: metainfo,
            layout: layout,
            selectablePieces: selectablePieces,
            mapper: mapper,
            downloadTotal: downloadTotal,
            peerID: peerID,
            rateLimiter: rateLimiter,
            active: ActivePeerCounter(),
            progress: progress
        )

        var lastError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<maxPeerConnections {
                group.addTask {
                    await Self.runWorker(supply: supply, coordinator: coordinator, writer: writer, context: context)
                }
            }
            // Supervisor: refill the reserve by re-announcing, and close the supply
            // (releasing any waiting workers) once the download is complete, stalls
            // out, or is cancelled — otherwise workers would block forever on an
            // empty-but-not-finished reserve.
            group.addTask {
                await Self.runSupervisor(supply: supply, coordinator: coordinator, refillPeers: refillPeers)
                return nil
            }
            // Completion watcher: end the run within ~1 s of the last piece verifying,
            // rather than waiting out a worker parked in an idle-timeout read or the
            // supervisor's re-announce sleep. Returns as soon as the swarm is done so
            // the loop below can cancel the remaining workers.
            group.addTask {
                while !(await coordinator.isComplete) {
                    if Task.isCancelled { return nil }
                    try? await Task.sleep(for: .seconds(1))
                }
                return nil
            }

            for await result in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let result {
                    lastError = result
                }
                // Once every piece is verified the transfer is over; cancel the still-
                // parked workers/supervisor (their reads are cancellation-aware) instead
                // of waiting for each to time out on its own.
                if await coordinator.isComplete {
                    group.cancelAll()
                    break
                }
            }
        }

        if await coordinator.isComplete {
            return await coordinator.downloadedBytes
        }
        throw lastError ?? TrackerClientError.invalidResponse
    }

    /// A single worker: keeps drawing peers from the shared reserve, connecting and
    /// draining each until it fails, then replacing it — until the coordinator is
    /// complete or the reserve is exhausted. Returns the last error seen (so the
    /// caller can surface a "no usable peers" failure) or `nil` on clean exit.
    private static func runWorker(
        supply: PeerSupply,
        coordinator: PieceDownloadCoordinator,
        writer: TorrentPieceWriter,
        context: WorkerContext
    ) async -> Error? {
        var lastError: Error?
        let pieceCount = context.metainfo.pieceHashes.count

        while true {
            if Task.isCancelled { return CancellationError() }
            if await coordinator.isComplete { return nil }
            guard let peer = await awaitNextPeer(supply: supply, coordinator: coordinator) else { return lastError }

            let client = PeerWireClient(endpoint: peer, infoHash: context.metainfo.infoHash, peerID: context.peerID)
            do {
                try Task.checkCancellation()
                // Only announce "Connecting" when nothing is downloading yet, so a
                // worker dialing a replacement doesn't stomp the "Downloading from N
                // peers" line the others are showing.
                if await context.active.count == 0 {
                    await context.progress(TorrentDownloadProgress(status: "Connecting to peers", downloadedBytes: await coordinator.downloadedBytes, totalBytes: context.downloadTotal))
                }
                try await withTimeout(seconds: .seconds(20)) {
                    try await client.connect()
                }
                let available = try await withTimeout(seconds: .seconds(10)) {
                    try await client.readInitialAvailability(pieceCount: pieceCount)
                }
                // An undeclared (empty) peer counts optimistically as a full seed
                // for rarest-first seeding; the live set is re-queried per piece.
                await coordinator.addAvailability(available.isEmpty ? Set(0..<pieceCount) : available)
            } catch is CancellationError {
                await client.close()
                return CancellationError()
            } catch {
                await client.close()
                lastError = error
                continue
            }

            _ = await context.active.increment(client)
            let peers = await context.active.snapshot()
            await context.progress(TorrentDownloadProgress(status: Self.downloadingStatus(peerCount: peers.connected), downloadedBytes: await coordinator.downloadedBytes, totalBytes: context.downloadTotal, connectedPeers: peers.connected, unchokedPeers: peers.unchoked))

            let outcome = await drainPeer(client: client, supply: supply, coordinator: coordinator, writer: writer, context: context)
            await client.close()
            await context.active.decrement(client)
            switch outcome {
            case .cancelled:
                return CancellationError()
            case .completed:
                return nil
            case let .peerEnded(error):
                if let error { lastError = error }
                continue
            }
        }
    }

    /// Draws the next reserve peer, waiting through transient empties so a worker
    /// doesn't quit the instant the reserve drains — the supervisor's periodic
    /// re-announce (and inbound PEX) may still refill it. Returns nil only once the
    /// supply is finished (download complete, stalled, or cancelled).
    private static func awaitNextPeer(
        supply: PeerSupply,
        coordinator: PieceDownloadCoordinator
    ) async -> PeerEndpoint? {
        while true {
            if Task.isCancelled { return nil }
            if let peer = await supply.next() { return peer }
            if await supply.isFinished { return nil }
            if await coordinator.isComplete { return nil }
            // Short poll: cheap next to a multi-GB transfer, and cancellation-safe
            // (a cancelled sleep just loops back to the checks above).
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Keeps the reserve fed and decides when the download is truly over. Re-announces
    /// on `reannounceInterval` to fold fresh tracker/DHT peers in, tracks byte
    /// progress, and gives up only after `stallDeadline` with no progress at all.
    /// Always closes the supply on exit so waiting workers are released.
    private static func runSupervisor(
        supply: PeerSupply,
        coordinator: PieceDownloadCoordinator,
        refillPeers: @Sendable () async -> [PeerEndpoint]
    ) async {
        let clock = ContinuousClock()
        var lastBytes = await coordinator.downloadedBytes
        var lastAdvance = clock.now
        while true {
            try? await Task.sleep(for: reannounceInterval)
            if Task.isCancelled { break }
            if await coordinator.isComplete { break }
            let fresh = await refillPeers()
            await supply.add(fresh)
            let bytes = await coordinator.downloadedBytes
            if bytes > lastBytes {
                lastBytes = bytes
                lastAdvance = clock.now
            } else if clock.now - lastAdvance > stallDeadline {
                break
            }
        }
        await supply.finish()
    }

    /// Drives one peer through the cross-piece pipeline: it keeps claiming the
    /// rarest needed piece this peer can serve and streaming blocks with an adaptive
    /// request window, holding the connection through chokes and ending only when the
    /// peer goes silent (snub/idle timeout), fails, or runs out of useful pieces. The
    /// worker replaces the peer on `.peerEnded`. All the throughput-critical looping
    /// now lives in `PeerWireClient.downloadPieces`; this method just wires the
    /// coordinator, writer, and progress reporting to it.
    private static func drainPeer(
        client: PeerWireClient,
        supply: PeerSupply,
        coordinator: PieceDownloadCoordinator,
        writer: TorrentPieceWriter,
        context: WorkerContext
    ) async -> DrainOutcome {
        let layout = context.layout
        let metainfo = context.metainfo
        let downloadTotal = context.downloadTotal
        let limiter = context.rateLimiter
        let progress = context.progress
        let mapper = context.mapper
        let active = context.active
        let selectablePieces = context.selectablePieces

        do {
            try await client.downloadPieces(
                pieceCount: layout.pieceCount,
                pieceLength: { layout.length(ofPiece: $0) },
                expectedHash: { metainfo.pieceHashes[$0] },
                claimNextPiece: { livePieces, isKnown, held in
                    // When the peer never declared availability (unchoked first), fall
                    // back optimistically to all selectable pieces; this self-corrects
                    // as soon as it announces anything.
                    let usable = isKnown ? livePieces : selectablePieces
                    return await coordinator.nextPiece(availablePieces: usable, excluding: held)
                },
                onPieceComplete: { pieceIndex, piece in
                    try await writer.write(piece: piece, pieceIndex: pieceIndex)
                    let (downloaded, perFileBytes) = await coordinator.complete(pieceIndex: pieceIndex)
                    guard let perFileBytes else { return }
                    let peers = await active.snapshot()
                    await progress(TorrentDownloadProgress(status: Self.downloadingStatus(peerCount: peers.connected), downloadedBytes: downloaded, totalBytes: downloadTotal, files: mapper.snapshot(perFileBytes: perFileBytes), connectedPeers: peers.connected, unchokedPeers: peers.unchoked))
                },
                onReturnPiece: { pieceIndex in
                    await coordinator.returnPiece(pieceIndex)
                },
                onBlock: { blockBytes in
                    // Pace at block granularity so the shared cap holds smoothly, and
                    // refresh the verified total on a throttle so the row stays lively.
                    await limiter?.consume(blockBytes)
                    if let verified = await coordinator.progressTick() {
                        let peers = await active.snapshot()
                        await progress(TorrentDownloadProgress(status: Self.downloadingStatus(peerCount: peers.connected), downloadedBytes: verified, totalBytes: downloadTotal, connectedPeers: peers.connected, unchokedPeers: peers.unchoked))
                    }
                },
                onPeersDiscovered: { peers in
                    // Fold peers this connection gossiped via PEX into the shared
                    // reserve so workers replacing dead peers can draw them.
                    await supply.add(peers)
                },
                completedElsewhere: { held in
                    // Endgame: which of this peer's in-flight pieces another peer has
                    // already finished, so downloadPieces can cancel their outstanding
                    // blocks instead of redownloading a verified duplicate.
                    await coordinator.completedAmong(held)
                }
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            // The peer failed or choked us out; downloadPieces has already handed back
            // every unfinished piece. No status update: one flaky peer among many
            // isn't worth flickering the shared line.
            return .peerEnded(error)
        }
        return await coordinator.isComplete ? .completed : .peerEnded(nil)
    }

    /// The shared, flicker-free download status: reflects how many peers are
    /// currently connected rather than any single worker's momentary state.
    private static func downloadingStatus(peerCount: Int) -> String {
        peerCount > 0 ? "Downloading from \(peerCount) peer\(peerCount == 1 ? "" : "s")" : "Downloading"
    }
}

private enum DrainOutcome {
    case cancelled
    case completed
    /// The peer stopped being useful (failed a piece or ran out). Carries the
    /// failure, if any, so the worker can surface it when the reserve is empty.
    case peerEnded(Error?)
}

/// Immutable per-download parameters shared by every worker, bundled so the
/// worker/drain helpers stay readable rather than taking a dozen arguments each.
private struct WorkerContext: Sendable {
    let metainfo: TorrentMetainfo
    let layout: TorrentLayout
    let selectablePieces: Set<Int>
    let mapper: FileProgressMapper
    let downloadTotal: Int64
    let peerID: Data
    let rateLimiter: RateLimiter?
    /// Count of peers currently connected, so the UI can show one stable
    /// "Downloading from N peers" line instead of 16 workers fighting over the
    /// status with per-peer "Connecting…/Connected…" messages.
    let active: ActivePeerCounter
    let progress: @Sendable (TorrentDownloadProgress) async -> Void
}

/// Tracks how many peers are actively connected. Lets every progress tick report
/// the same aggregate status rather than each worker's momentary per-peer state,
/// which otherwise flickers between "Connecting" and "Downloading".
actor ActivePeerCounter {
    private var clients: [ObjectIdentifier: PeerWireClient] = [:]
    var count: Int { clients.count }
    func increment(_ client: PeerWireClient) -> Int {
        clients[ObjectIdentifier(client)] = client
        return clients.count
    }
    func decrement(_ client: PeerWireClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
    }
    /// Connected and unchoked-us counts, read live from the clients: tells a swarm
    /// full of peers apart from one where few of them will send us data.
    func snapshot() async -> (connected: Int, unchoked: Int) {
        let live = Array(clients.values)
        var unchoked = 0
        for client in live where await !client.isChokingUs { unchoked += 1 }
        return (live.count, unchoked)
    }
}

/// Shared reserve of candidate peers handed out to workers one at a time. Backs
/// peer-pool replenishment: as workers' peers die they pull fresh ones from here
/// without ever handing the same endpoint to two workers.
actor PeerSupply {
    /// Most endpoints ever queued. PEX and re-announces keep feeding the reserve
    /// for the life of a download; a hostile peer must not make it grow forever.
    static let maxPeers = 5_000

    private var remaining: [PeerEndpoint]
    private var index = 0
    /// Every endpoint ever queued, so PEX-discovered peers that are already in the
    /// reserve (or were handed out) are not enqueued twice.
    private var seen: Set<PeerEndpoint>
    /// Set once the download is over (complete, stalled out, or cancelled). Tells
    /// workers waiting on an empty reserve to stop rather than keep polling for a
    /// refill that will never come.
    private var finished = false

    init(peers: [PeerEndpoint]) {
        self.remaining = peers
        self.seen = Set(peers)
    }

    var isFinished: Bool { finished }

    /// Whether any peer is still waiting to be handed out.
    var hasUntriedPeers: Bool { index < remaining.count }

    func next() -> PeerEndpoint? {
        guard index < remaining.count else { return nil }
        defer { index += 1 }
        return remaining[index]
    }

    /// Enqueues newly discovered peers (from inbound PEX or a periodic tracker/DHT
    /// re-announce) that have not been queued before, so workers replacing dead
    /// peers can draw them. Returns how many were actually added.
    @discardableResult
    func add(_ peers: [PeerEndpoint]) -> Int {
        var added = 0
        for peer in peers where !seen.contains(peer) {
            guard seen.count < Self.maxPeers else { break }
            seen.insert(peer)
            remaining.append(peer)
            added += 1
        }
        return added
    }

    /// Marks the reserve permanently closed, releasing workers that are waiting
    /// for a refill.
    func finish() { finished = true }
}

/// Serializes piece writes onto the shared file writer so concurrent peer tasks
/// never write overlapping file ranges at the same time.
private actor TorrentPieceWriter {
    private let writer: TorrentFileWriter

    init(writer: TorrentFileWriter) {
        self.writer = writer
    }

    func write(piece: Data, pieceIndex: Int) throws {
        try writer.write(piece: piece, pieceIndex: pieceIndex)
    }
}
