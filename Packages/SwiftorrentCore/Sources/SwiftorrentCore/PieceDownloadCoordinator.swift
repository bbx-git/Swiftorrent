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
    private var availabilityCounts: [Int: Int]
    private var pendingPieces: Set<Int>
    private var activePieces = Set<Int>()
    private var completedPieces: Set<Int>
    private var completedBytes: Int64
    private var perFileBytes: [Int64]
    /// Bytes received for pieces still in flight, keyed by piece. Folded into the
    /// reported total so the download rate tracks bytes as they arrive rather than
    /// jumping a whole piece at a time when one verifies. Cleared when a piece
    /// completes (its bytes move into `completedBytes`) or is returned (partial
    /// bytes are discarded).
    private var inflightByPiece: [Int: Int64] = [:]
    private let clock = ContinuousClock()
    private var lastReport: ContinuousClock.Instant?

    init(layout: TorrentLayout, selectablePieces: Set<Int>, completedPieces: Set<Int>, initialDownloaded: Int64, availabilityCounts: [Int: Int]) {
        self.layout = layout
        self.completedPieces = completedPieces
        self.completedBytes = initialDownloaded
        self.availabilityCounts = availabilityCounts
        self.pendingPieces = selectablePieces.subtracting(completedPieces)
        self.perFileBytes = layout.completedBytesPerFile(completedPieces: completedPieces)
    }

    var downloadedBytes: Int64 {
        completedBytes + inflightByPiece.values.reduce(0, +)
    }

    /// Records freshly received in-flight bytes for an active piece. Returns the
    /// current overall total (completed + in-flight) when enough time has elapsed
    /// since the last report to warrant a UI refresh, or `nil` to coalesce this
    /// update away so a fast unlimited download can't flood the progress channel.
    func recordInflight(pieceIndex: Int, bytes: Int) -> Int64? {
        inflightByPiece[pieceIndex, default: 0] += Int64(bytes)
        let now = clock.now
        if let last = lastReport, now - last < .milliseconds(200) { return nil }
        lastReport = now
        return downloadedBytes
    }

    var isComplete: Bool {
        pendingPieces.isEmpty && activePieces.isEmpty
    }

    /// Folds a newly connected peer's available pieces into the rarest-first
    /// counts. Called as the worker pool replaces dead peers so piece ordering
    /// reflects the live swarm rather than just the peers seen at startup.
    func addAvailability(_ pieces: Set<Int>) {
        for piece in pieces {
            availabilityCounts[piece, default: 0] += 1
        }
    }

    func nextPiece(availablePieces: Set<Int>) -> Int? {
        let candidates = pendingPieces.intersection(availablePieces)
        guard let piece = candidates.min(by: { left, right in
            let leftCount = availabilityCounts[left, default: Int.max]
            let rightCount = availabilityCounts[right, default: Int.max]
            if leftCount == rightCount { return left < right }
            return leftCount < rightCount
        }) else {
            return nil
        }
        pendingPieces.remove(piece)
        activePieces.insert(piece)
        return piece
    }

    func complete(pieceIndex: Int) -> (downloadedBytes: Int64, perFileBytes: [Int64]) {
        guard activePieces.remove(pieceIndex) != nil, !completedPieces.contains(pieceIndex) else {
            return (downloadedBytes, perFileBytes)
        }
        // Move this piece's bytes from the in-flight tally into the completed
        // total so the reported total stays continuous across completion.
        inflightByPiece[pieceIndex] = nil
        completedPieces.insert(pieceIndex)
        completedBytes += Int64(layout.length(ofPiece: pieceIndex))
        // Fold just this piece's slices into the running per-file tally instead
        // of recomputing the whole table each completion.
        for (id, bytes) in layout.completedBytesPerFile(completedPieces: [pieceIndex]).enumerated() where bytes > 0 {
            perFileBytes[id] += bytes
        }
        return (downloadedBytes, perFileBytes)
    }

    func returnPiece(_ pieceIndex: Int) {
        guard activePieces.remove(pieceIndex) != nil, !completedPieces.contains(pieceIndex) else {
            return
        }
        // Discard any partial bytes downloaded for the abandoned piece so the
        // total doesn't overcount work that has to be redone.
        inflightByPiece[pieceIndex] = nil
        pendingPieces.insert(pieceIndex)
    }
}
