import Foundation

/// Serializes piece scheduling and accounting across the concurrent peer pool.
/// Hands out the rarest still-needed piece each peer can serve, folds completed
/// pieces into running overall/per-file byte tallies, and returns abandoned
/// pieces to the pending set so another peer can retry them.
actor PieceDownloadCoordinator {
    private let layout: TorrentLayout
    /// Per-piece availability across the peers seen so far, used only to order
    /// rarest-first piece selection. Mutable because the swarm is dynamic: workers
    /// fold in each freshly connected peer via `addAvailability` so the ordering
    /// keeps refining as peers join and leave.
    /// Indexed by piece; `Int.max` means no peer has been seen with that piece, so
    /// it sorts as least rare. A flat array keeps the per-claim scan cache-friendly.
    private var availabilityCounts: [Int]
    private var pendingPieces: Set<Int>
    /// In-flight pieces mapped to the number of peers currently downloading each.
    /// Normally 1, but **endgame** hands the same piece to several peers at once
    /// (so the last pieces aren't gated by one slow peer), so this is a count, not a
    /// set: a piece stays in flight until its *last* holder returns it, and only its
    /// first completion is counted.
    private var assignments: [Int: Int] = [:]
    private var completedPieces: Set<Int>
    private var completedBytes: Int64
    private var perFileBytes: [Int64]
    private let clock = ContinuousClock()
    private var lastReport: ContinuousClock.Instant?
    private var lastPieceReport: ContinuousClock.Instant?

    init(layout: TorrentLayout, selectablePieces: Set<Int>, completedPieces: Set<Int>, initialDownloaded: Int64, availabilityCounts: [Int: Int]) {
        self.layout = layout
        self.completedPieces = completedPieces
        self.completedBytes = initialDownloaded
        var counts = [Int](repeating: Int.max, count: layout.pieceCount)
        for (piece, count) in availabilityCounts where piece >= 0 && piece < counts.count {
            counts[piece] = count
        }
        self.availabilityCounts = counts
        self.pendingPieces = selectablePieces.subtracting(completedPieces)
        self.perFileBytes = layout.completedBytesPerFile(completedPieces: completedPieces)
    }

    /// Bytes of fully downloaded, SHA-1-verified, written pieces. This only ever
    /// increases: partial bytes of a piece whose peer died mid-transfer are not
    /// counted (the piece is re-fetched whole), so the reported total never jumps
    /// backward the way "completed + in-flight" did.
    var downloadedBytes: Int64 {
        completedBytes
    }

    /// A throttled progress ping for the per-block download callback: returns the
    /// current verified total at most every 200 ms (`nil` in between) so a fast
    /// download can't flood the progress channel. The reported number moves only
    /// when pieces actually complete, which is fine — with a wide worker pool a
    /// piece finishes every second or two, keeping the bar lively but monotonic.
    func progressTick() -> Int64? {
        let now = clock.now
        if let last = lastReport, now - last < .milliseconds(200) { return nil }
        lastReport = now
        return completedBytes
    }

    /// Whether a piece-completion progress update should be sent now: true at most
    /// every 200 ms. Each update carries an all-files snapshot that the UI folds in
    /// on the main thread, so a fast download of a many-file torrent must not send
    /// one per piece. The final state is reported separately on completion.
    func pieceProgressDue() -> Bool {
        let now = clock.now
        if let last = lastPieceReport, now - last < .milliseconds(200) { return false }
        lastPieceReport = now
        return true
    }

    var isComplete: Bool {
        pendingPieces.isEmpty && assignments.isEmpty
    }

    /// Folds a newly connected peer's available pieces into the rarest-first
    /// counts. Called as the worker pool replaces dead peers so piece ordering
    /// reflects the live swarm rather than just the peers seen at startup.
    func addAvailability(_ pieces: Set<Int>) {
        for piece in pieces where piece >= 0 && piece < availabilityCounts.count {
            availabilityCounts[piece] = availabilityCounts[piece] == Int.max ? 1 : availabilityCounts[piece] + 1
        }
    }

    /// Hands out the next piece for a peer to download. `excluding` is the set the
    /// peer is already assembling, so endgame never hands a peer a piece it holds.
    ///
    /// Normal path: the rarest still-*unassigned* piece the peer can serve. Endgame
    /// (no unassigned piece remains anywhere): a duplicate of the least-duplicated
    /// in-flight piece the peer can serve, so several peers race the final pieces and
    /// the tail isn't held hostage by one slow seed.
    func nextPiece(availablePieces: Set<Int>, excluding: Set<Int> = []) -> Int? {
        // One pass with no intermediate set: `pendingPieces.intersection(...)` allocated
        // a set the size of the torrent on every claim, which dominated large torrents.
        var rarest: Int?
        var rarestCount = Int.max
        for piece in pendingPieces where availablePieces.contains(piece) {
            let count = piece >= 0 && piece < availabilityCounts.count ? availabilityCounts[piece] : Int.max
            if rarest == nil || count < rarestCount || (count == rarestCount && piece < rarest!) {
                rarest = piece
                rarestCount = count
            }
        }
        if let piece = rarest {
            pendingPieces.remove(piece)
            assignments[piece, default: 0] += 1
            return piece
        }

        // Endgame: every remaining piece is already in flight. Duplicate the
        // least-duplicated one this peer can serve and isn't already working on.
        guard pendingPieces.isEmpty else { return nil }
        let endgame = assignments.keys.filter { availablePieces.contains($0) && !excluding.contains($0) }
        guard let piece = endgame.min(by: { left, right in
            let leftCount = assignments[left, default: 0]
            let rightCount = assignments[right, default: 0]
            if leftCount == rightCount { return left < right }
            return leftCount < rightCount
        }) else {
            return nil
        }
        assignments[piece, default: 0] += 1
        return piece
    }

    func complete(pieceIndex: Int) -> (downloadedBytes: Int64, perFileBytes: [Int64]) {
        // Guard on completion, not membership: with endgame duplicates a second peer
        // may report the same piece, and it may even have been requeued meanwhile.
        // The first completion counts; the rest are harmless no-ops.
        guard !completedPieces.contains(pieceIndex) else {
            return (downloadedBytes, perFileBytes)
        }
        assignments[pieceIndex] = nil
        pendingPieces.remove(pieceIndex)
        completedPieces.insert(pieceIndex)
        completedBytes += Int64(layout.length(ofPiece: pieceIndex))
        // Fold just this piece's slices into the running per-file tally instead
        // of recomputing the whole table each completion.
        for (id, bytes) in layout.completedBytesPerFile(completedPieces: [pieceIndex]).enumerated() where bytes > 0 {
            perFileBytes[id] += bytes
        }
        return (downloadedBytes, perFileBytes)
    }

    /// Endgame support: of the pieces a peer is still assembling, which have already
    /// been completed by another peer. The peer cancels its outstanding block
    /// requests for these and drops them, so the tail isn't spent finishing an
    /// already-verified duplicate. Returns an empty set outside endgame (nothing a
    /// peer holds has been completed elsewhere), so it's a cheap no-op on the hot path.
    func completedAmong(_ pieces: Set<Int>) -> Set<Int> {
        guard !pieces.isEmpty else { return [] }
        return completedPieces.intersection(pieces)
    }

    func returnPiece(_ pieceIndex: Int) {
        guard !completedPieces.contains(pieceIndex), let count = assignments[pieceIndex] else {
            return
        }
        if count <= 1 {
            // The last holder gave up: requeue the piece so another peer can fetch it.
            assignments[pieceIndex] = nil
            pendingPieces.insert(pieceIndex)
        } else {
            // Other peers (endgame duplicates) are still on it; just drop this holder.
            assignments[pieceIndex] = count - 1
        }
    }
}
