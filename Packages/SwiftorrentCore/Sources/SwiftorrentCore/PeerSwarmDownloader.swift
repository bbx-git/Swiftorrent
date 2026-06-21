import Foundation

/// Downloads pieces from a swarm of peers over the peer-wire protocol. Connects
/// a bounded pool of peers, then runs one task per peer that repeatedly pulls
/// the rarest needed piece from a shared `PieceDownloadCoordinator`, downloads
/// and verifies it, and writes it to disk. Returns the total downloaded byte
/// count once every selectable piece is present.
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
        let sessions = try await connectPeerSessions(
            peers: peers,
            metainfo: metainfo,
            peerID: peerID,
            initialDownloaded: initialDownloaded,
            totalBytes: downloadTotal,
            progress: progress
        )
        guard !sessions.isEmpty else { throw TrackerClientError.invalidResponse }

        let writer = TorrentPieceWriter(writer: TorrentFileWriter(metainfo: metainfo, destination: destination, stripRootDirectory: stripRootDirectory))
        let coordinator = PieceDownloadCoordinator(
            layout: layout,
            selectablePieces: selectablePieces,
            completedPieces: verifiedPieces,
            initialDownloaded: initialDownloaded,
            availabilityCounts: availabilityCounts(from: sessions)
        )

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
                            let limiter = rateLimiter
                            let piece = try await withTimeout(seconds: .seconds(60)) {
                                try await session.client.downloadPiece(index: pieceIndex, length: length, expectedHash: metainfo.pieceHashes[pieceIndex]) { blockBytes in
                                    // Pace at block granularity so the shared cap
                                    // holds smoothly instead of a whole piece
                                    // arriving full-speed and then sleeping.
                                    await limiter?.consume(blockBytes)
                                    // Report bytes as they land (coalesced) so the
                                    // speed readout tracks the true rate instead of
                                    // jumping a whole piece at a time.
                                    if let live = await coordinator.recordInflight(pieceIndex: pieceIndex, bytes: blockBytes) {
                                        await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: live, totalBytes: downloadTotal))
                                    }
                                }
                            }
                            try await writer.write(piece: piece, pieceIndex: pieceIndex)
                            let (downloaded, perFileBytes) = await coordinator.complete(pieceIndex: pieceIndex)
                            await progress(TorrentDownloadProgress(status: "Downloading", downloadedBytes: downloaded, totalBytes: downloadTotal, files: mapper.snapshot(perFileBytes: perFileBytes)))
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

    private func closeSessions(_ sessions: [PeerDownloadSession]) async {
        for session in sessions {
            await session.client.close()
        }
    }

    private func availabilityCounts(from sessions: [PeerDownloadSession]) -> [Int: Int] {
        sessions.reduce(into: [Int: Int]()) { counts, session in
            for piece in session.availablePieces {
                counts[piece, default: 0] += 1
            }
        }
    }
}

private struct PeerDownloadSession: Sendable {
    let endpoint: PeerEndpoint
    let client: PeerWireClient
    let availablePieces: Set<Int>
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
