import Foundation

/// Downloads pieces from a swarm of peers over the peer-wire protocol. Runs a
/// bounded pool of `maxPeerConnections` worker tasks; each worker pulls a fresh
/// peer from a shared `PeerSupply` reserve, connects, and repeatedly downloads
/// the rarest needed piece from a shared `PieceDownloadCoordinator`, writing each
/// verified piece to disk. When a peer fails or runs out of useful pieces the
/// worker closes it and draws a **replacement** peer from the reserve, so the
/// swarm keeps refilling toward `maxPeerConnections` active connections instead
/// of bleeding out as peers die. Returns the total downloaded byte count once
/// every selectable piece is present.
struct PeerSwarmDownloader: Sendable {
    let maxPeerConnections: Int
    var rateLimiter: RateLimiter? = nil

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
            progress: progress
        )

        var lastError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<maxPeerConnections {
                group.addTask {
                    await Self.runWorker(supply: supply, coordinator: coordinator, writer: writer, context: context)
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
            guard let peer = await supply.next() else { return lastError }

            let client = PeerWireClient(endpoint: peer, infoHash: context.metainfo.infoHash, peerID: context.peerID)
            do {
                try Task.checkCancellation()
                await context.progress(TorrentDownloadProgress(status: "Connecting to peer \(peer.host):\(peer.port)", downloadedBytes: await coordinator.downloadedBytes, totalBytes: context.downloadTotal))
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

            await context.progress(TorrentDownloadProgress(status: "Connected to peer \(peer.host):\(peer.port)", downloadedBytes: await coordinator.downloadedBytes, totalBytes: context.downloadTotal))

            let outcome = await drainPeer(client: client, peer: peer, coordinator: coordinator, writer: writer, context: context)
            await client.close()
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

    /// Pulls the rarest needed piece this peer can serve, downloads and verifies it,
    /// and writes it — looping until the peer fails, the coordinator finishes, or the
    /// peer has no more useful pieces. The worker replaces the peer on `.peerEnded`.
    private static func drainPeer(
        client: PeerWireClient,
        peer: PeerEndpoint,
        coordinator: PieceDownloadCoordinator,
        writer: TorrentPieceWriter,
        context: WorkerContext
    ) async -> DrainOutcome {
        let metainfo = context.metainfo
        let layout = context.layout
        let downloadTotal = context.downloadTotal
        let limiter = context.rateLimiter
        let progress = context.progress

        while true {
            try? Task.checkCancellation()
            guard !Task.isCancelled else { return .cancelled }
            // Pull live availability each pass so `have`/`bitfield` messages received
            // mid-download refine the set. When the peer never declared availability
            // (unchoked first), fall back optimistically to all selectable pieces;
            // this self-corrects as soon as the peer announces anything.
            let (livePieces, isKnown) = await client.currentAvailability()
            let usablePieces = isKnown ? livePieces : context.selectablePieces
            guard let pieceIndex = await coordinator.nextPiece(availablePieces: usablePieces) else {
                // No more pieces this peer can serve: either we are done, or other
                // peers hold what is left and this worker should fetch a new peer.
                return await coordinator.isComplete ? .completed : .peerEnded(nil)
            }

            do {
                let length = layout.length(ofPiece: pieceIndex)
                await progress(TorrentDownloadProgress(status: "Downloading piece \(pieceIndex + 1) of \(metainfo.pieceHashes.count)", downloadedBytes: await coordinator.downloadedBytes, totalBytes: downloadTotal))
                let piece = try await withTimeout(seconds: .seconds(60)) {
                    try await client.downloadPiece(index: pieceIndex, length: length, expectedHash: metainfo.pieceHashes[pieceIndex]) { blockBytes in
                        // Pace at block granularity so the shared cap holds smoothly
                        // instead of a whole piece arriving full-speed then sleeping.
                        await limiter?.consume(blockBytes)
                        // Report bytes as they land (coalesced) so the speed readout
                        // tracks the true rate instead of jumping a whole piece at a time.
                        if let live = await coordinator.recordInflight(pieceIndex: pieceIndex, bytes: blockBytes) {
                            await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: live, totalBytes: downloadTotal))
                        }
                    }
                }
                try await writer.write(piece: piece, pieceIndex: pieceIndex)
                let (downloaded, perFileBytes) = await coordinator.complete(pieceIndex: pieceIndex)
                await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: downloaded, totalBytes: downloadTotal, files: context.mapper.snapshot(perFileBytes: perFileBytes)))
            } catch is CancellationError {
                await coordinator.returnPiece(pieceIndex)
                return .cancelled
            } catch {
                // Return the piece so another peer (this worker's replacement or a
                // concurrent one) retries it, then end this peer.
                await coordinator.returnPiece(pieceIndex)
                await progress(TorrentDownloadProgress(status: "Peer \(peer.host):\(peer.port) failed piece \(pieceIndex + 1).", downloadedBytes: await coordinator.downloadedBytes, totalBytes: downloadTotal))
                return .peerEnded(error)
            }
        }
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
    let progress: @Sendable (TorrentDownloadProgress) async -> Void
}

/// Shared reserve of candidate peers handed out to workers one at a time. Backs
/// peer-pool replenishment: as workers' peers die they pull fresh ones from here
/// without ever handing the same endpoint to two workers.
actor PeerSupply {
    private var remaining: [PeerEndpoint]
    private var index = 0

    init(peers: [PeerEndpoint]) {
        self.remaining = peers
    }

    func next() -> PeerEndpoint? {
        guard index < remaining.count else { return nil }
        defer { index += 1 }
        return remaining[index]
    }
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
