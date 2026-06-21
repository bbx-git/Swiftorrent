import Foundation

/// Serializes piece scheduling and accounting across the concurrent peer pool.
/// Hands out the rarest still-needed piece each peer can serve, folds completed
/// pieces into running overall/per-file byte tallies, and returns abandoned
/// pieces to the pending set so another peer can retry them.
actor PieceDownloadCoordinator {
    private let layout: TorrentLayout
    private let availabilityCounts: [Int: Int]
    private var pendingPieces: Set<Int>
    private var activePieces = Set<Int>()
    private var completedPieces: Set<Int>
    private var completedBytes: Int64
    private var perFileBytes: [Int64]

    init(layout: TorrentLayout, selectablePieces: Set<Int>, completedPieces: Set<Int>, initialDownloaded: Int64, availabilityCounts: [Int: Int]) {
        self.layout = layout
        self.completedPieces = completedPieces
        self.completedBytes = initialDownloaded
        self.availabilityCounts = availabilityCounts
        self.pendingPieces = selectablePieces.subtracting(completedPieces)
        self.perFileBytes = layout.completedBytesPerFile(completedPieces: completedPieces)
    }

    var downloadedBytes: Int64 {
        completedBytes
    }

    var isComplete: Bool {
        pendingPieces.isEmpty && activePieces.isEmpty
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
            return (completedBytes, perFileBytes)
        }
        completedPieces.insert(pieceIndex)
        completedBytes += Int64(layout.length(ofPiece: pieceIndex))
        // Fold just this piece's slices into the running per-file tally instead
        // of recomputing the whole table each completion.
        for (id, bytes) in layout.completedBytesPerFile(completedPieces: [pieceIndex]).enumerated() where bytes > 0 {
            perFileBytes[id] += bytes
        }
        return (completedBytes, perFileBytes)
    }

    func returnPiece(_ pieceIndex: Int) {
        guard activePieces.remove(pieceIndex) != nil, !completedPieces.contains(pieceIndex) else {
            return
        }
        pendingPieces.insert(pieceIndex)
    }
}
