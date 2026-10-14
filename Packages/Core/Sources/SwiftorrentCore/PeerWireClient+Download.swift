import CryptoKit
import Foundation

extension PeerWireClient {
    /// Downloads a continuous stream of pieces from this peer over a **cross-piece**
    /// request pipeline, the way a mainstream client (libtorrent/qBittorrent) drives a
    /// peer connection. Key behaviours:
    ///
    /// - **Cross-piece pipelining.** A window of block requests is kept outstanding
    ///   at all times, spanning piece boundaries — the moment a piece's last block is
    ///   requested the pipeline claims the next piece and keeps filling, so the peer's
    ///   send queue never drains between pieces (the inter-piece bubble that pins a
    ///   fast seed below its line rate).
    /// - **Adaptive window.** The window is sized to ~`requestQueueTargetSeconds` of
    ///   the peer's *measured* rate, clamped to `[minPipelinedBlocks, maxPipelinedBlocks]`,
    ///   so a slow peer keeps a shallow queue and a fast seed a deep one.
    /// - **Hold through chokes.** A choke is normal, not a reason to disconnect. On a
    ///   choke we requeue the discarded requests and keep the connection open, waiting
    ///   for the peer to unchoke us again — the connection is dropped only on *silence*
    ///   (`idleTimeout`), so a still-alive peer that may unchoke us later is retained
    ///   like an entry in a mainstream client's large peer pool.
    /// - **Snubbing.** Once unchoked with requests outstanding, a peer that stops
    ///   sending data for `snubTimeout` is snubbing us; we drop it (via a read timeout)
    ///   so the worker can draw a fresher peer. That is BitTorrent's true "not
    ///   delivering" signal — no *data* — rather than merely "still choked".
    ///
    /// Pieces are claimed lazily via `claimNextPiece`, assembled out of order,
    /// SHA-1-verified on completion, and handed to `onPieceComplete` (write +
    /// accounting). Every claimed-but-unfinished piece is handed back via
    /// `onReturnPiece` on any early exit so the coordinator can requeue it.
    ///
    /// - `claimNextPiece` receives this peer's live availability (whether it was
    ///   declared, and the pieces this peer is already assembling so endgame never
    ///   re-hands one) and returns the next piece to fetch, or nil when the peer has
    ///   nothing more we need — at which point the session ends cleanly.
    /// - `onBlock` is awaited per block with its byte count (rate-limit pacing +
    ///   live-speed accounting); `onPeersDiscovered` folds inbound PEX gossip.
    /// - `completedElsewhere` (endgame): given the pieces this peer is still
    ///   assembling, returns the subset another peer has already finished. We send a
    ///   BEP-3 `cancel` for each still-outstanding block of those pieces and drop
    ///   them, reclaiming the tail bandwidth endgame duplication would otherwise burn
    ///   finishing an already-verified copy. Polled on a throttle so it stays off the
    ///   hot path, and returns empty outside endgame.
    public func downloadPieces(
        blockSize: Int = 16 * 1024,
        pieceCount: Int? = nil,
        pieceLength: @Sendable (Int) -> Int,
        expectedHash: @Sendable (Int) -> Data,
        claimNextPiece: @Sendable (_ available: Set<Int>, _ isKnown: Bool, _ held: Set<Int>) async -> Int?,
        onPieceComplete: @Sendable (Int, Data) async throws -> Void,
        onReturnPiece: @Sendable (Int) async -> Void,
        onBlock: (@Sendable (Int) async -> Void)? = nil,
        onPeersDiscovered: (@Sendable ([PeerEndpoint]) async -> Void)? = nil,
        completedElsewhere: (@Sendable (_ held: Set<Int>) async -> Set<Int>)? = nil
    ) async throws {
        if let pieceCount { knownPieceCount = pieceCount }
        var active: [Int: PieceAssembly] = [:]           // claimed, still assembling
        var requestQueue: [(piece: Int, begin: Int, length: Int)] = []   // not yet requested
        var outstanding = Set<BlockKey>()                // requested, awaiting data
        var noMorePieces = false

        // Adaptive request window: recomputed ~once a second from the peer's measured
        // rate so the in-flight depth tracks its bandwidth. Starts at the floor and
        // grows as data flows.
        let clock = ContinuousClock()
        var windowCap = Self.minPipelinedBlocks
        var rateWindowStart = clock.now
        var rateWindowBytes = 0
        // Endgame: throttle how often we ask whether a held piece was completed by
        // another peer, so this stays off the per-block hot path.
        var lastCancelCheck = clock.now
        // When the last block of data arrived (or when we first started waiting for
        // one). The snub deadline runs from here and is NOT extended by keep-alives
        // or other chatter, so a peer cannot hold a worker slot without sending data.
        var lastDataAt = clock.now

        func returnAll() async {
            for index in active.keys { await onReturnPiece(index) }
        }

        do {
            while true {
                try Task.checkCancellation()

                // Resize the request window from the rate measured over the last ~1 s.
                let sinceRateSample = rateWindowStart.duration(to: clock.now)
                let rateSeconds = Double(sinceRateSample.components.seconds) + Double(sinceRateSample.components.attoseconds) / 1e18
                if rateSeconds >= 1 {
                    let bytesPerSecond = Double(rateWindowBytes) / rateSeconds
                    let target = Int(bytesPerSecond * Self.requestQueueTargetSeconds / Double(blockSize))
                    windowCap = min(Self.maxPipelinedBlocks, max(Self.minPipelinedBlocks, target))
                    rateWindowStart = clock.now
                    rateWindowBytes = 0
                }

                // Endgame cancel: drop any held piece another peer already finished and
                // send a `cancel` for its still-outstanding blocks, so we don't spend
                // the tail redownloading a verified duplicate. Throttled; a no-op until
                // endgame (when the same piece is handed to several peers at once).
                if let completedElsewhere, !active.isEmpty,
                   lastCancelCheck.duration(to: clock.now) >= .milliseconds(250) {
                    lastCancelCheck = clock.now
                    for piece in await completedElsewhere(Set(active.keys)) {
                        active.removeValue(forKey: piece)
                        requestQueue.removeAll { $0.piece == piece }
                        let toCancel = outstanding.filter { $0.piece == piece }
                        outstanding.subtract(toCancel)
                        for key in toCancel {
                            let length = min(blockSize, pieceLength(piece) - key.begin)
                            var payload = Data()
                            payload.appendUInt32(UInt32(key.piece))
                            payload.appendUInt32(UInt32(key.begin))
                            payload.appendUInt32(UInt32(length))
                            try await sendMessage(id: 8, payload: payload)
                        }
                    }
                }

                // Fill the pipeline while unchoked: claim fresh pieces as the queue
                // drains and send block requests until the (adaptive) window is full
                // or the peer has nothing left we need.
                while !isChoked, outstanding.count < windowCap {
                    if requestQueue.isEmpty {
                        if noMorePieces { break }
                        // Fold peers this connection gossiped before claiming more work.
                        if let onPeersDiscovered {
                            let gossiped = takeDiscoveredPeers()
                            if !gossiped.isEmpty { await onPeersDiscovered(gossiped) }
                        }
                        guard let index = await claimNextPiece(availablePieces, availabilityIsKnown, Set(active.keys)) else {
                            noMorePieces = true
                            break
                        }
                        let length = pieceLength(index)
                        var begins: [Int] = []
                        var offset = 0
                        while offset < length { begins.append(offset); offset += blockSize }
                        active[index] = PieceAssembly(length: length, blockBegins: begins, hash: expectedHash(index))
                        for begin in begins {
                            requestQueue.append((index, begin, min(blockSize, length - begin)))
                        }
                    }
                    guard !requestQueue.isEmpty else { break }
                    let request = requestQueue.removeFirst()
                    if outstanding.isEmpty { lastDataAt = clock.now }
                    var payload = Data()
                    payload.appendUInt32(UInt32(request.piece))
                    payload.appendUInt32(UInt32(request.begin))
                    payload.appendUInt32(UInt32(request.length))
                    try await sendMessage(id: 6, payload: payload)
                    outstanding.insert(BlockKey(piece: request.piece, begin: request.begin))
                }

                // Everything claimed has been assembled and the peer has nothing more
                // we need: a clean end (the worker draws its next peer).
                if active.isEmpty && noMorePieces { return }

                // Read the next message. With requests outstanding we expect data, so a
                // short `snubTimeout` reaps a peer that stalls; otherwise (choked/idle)
                // we wait the longer `idleTimeout`, keeping the connection open for a
                // possible unchoke rather than dropping it. A fired timeout throws
                // `.timedOut`, which the outer catch turns into a peer replacement.
                let readTimeout = outstanding.isEmpty ? idleTimeout : snubTimeout
                let snubDeadline: ContinuousClock.Instant? = outstanding.isEmpty
                    ? nil
                    : lastDataAt + .seconds(snubTimeout)
                let message = try await readMessage(timeout: readTimeout, deadline: snubDeadline)

                switch message.id {
                case 0:
                    // Choke: the peer drops every request in flight. Requeue the
                    // still-missing blocks (front of the queue) to re-send on unchoke.
                    isChoked = true
                    for key in outstanding {
                        guard let asm = active[key.piece] else { continue }
                        requestQueue.insert((key.piece, key.begin, min(blockSize, asm.length - key.begin)), at: 0)
                    }
                    outstanding.removeAll()
                case 1:
                    isChoked = false
                case 4, 5:
                    handlePeerStateMessage(message)
                case 7:
                    guard message.payload.count >= 8 else { throw PeerWireError.unexpectedMessage }
                    let pieceIndex = Int(message.payload.readUInt32(at: 0))
                    let begin = Int(message.payload.readUInt32(at: 4))
                    let data = Data(message.payload.dropFirst(8))
                    outstanding.remove(BlockKey(piece: pieceIndex, begin: begin))
                    guard let asm = active[pieceIndex] else { continue }   // stale/unwanted
                    // We only ever request whole blocks on a fixed grid, so anything else
                    // is a misbehaving peer.
                    guard begin >= 0, begin % blockSize == 0, begin < asm.length,
                          data.count == min(blockSize, asm.length - begin) else {
                        throw PeerWireError.unexpectedMessage
                    }
                    lastDataAt = clock.now
                    if asm.received.insert(begin).inserted {
                        asm.data.replaceSubrange(begin..<(begin + data.count), with: data)
                        rateWindowBytes += data.count
                        await onBlock?(data.count)
                        if asm.received.count == asm.blockBegins.count {
                            active.removeValue(forKey: pieceIndex)
                            guard Data(Insecure.SHA1.hash(data: asm.data)) == asm.hash else {
                                await onReturnPiece(pieceIndex)
                                throw PeerWireError.invalidPieceHash
                            }
                            try await onPieceComplete(pieceIndex, asm.data)
                        }
                    }
                case 20:
                    handleExtendedMessage(message.payload)
                default:
                    continue
                }
            }
        } catch {
            // Any early exit (choke-out, disconnect, cancellation, bad piece): hand
            // every still-unfinished piece back so another peer retries it.
            await returnAll()
            throw error
        }
    }
}

/// A piece being assembled block-by-block inside a peer session. A reference type
/// so the pipeline mutates its buffer in place — copying a 256 KB `Data` value on
/// every one of the ~16 blocks per piece would swamp the transfer. Lives only in
/// `PeerWireClient`'s actor-isolated state, so it never crosses a concurrency
/// boundary and needs no `Sendable` conformance.
private final class PieceAssembly {
    var data: Data
    var received = Set<Int>()
    let blockBegins: [Int]
    let length: Int
    let hash: Data

    init(length: Int, blockBegins: [Int], hash: Data) {
        self.data = Data(count: length)
        self.blockBegins = blockBegins
        self.length = length
        self.hash = hash
    }
}

/// Identifies one outstanding block request by its piece and offset, so a block
/// can be matched back to its request across piece boundaries in the pipeline.
private struct BlockKey: Hashable {
    let piece: Int
    let begin: Int
}
