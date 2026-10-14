import Foundation

/// Pure geometry for a torrent: how pieces map onto the linear byte stream and
/// onto individual files. Both file selection (which pieces to download) and
/// per-file progress (how many of a file's bytes are covered by completed
/// pieces) are derived from this, so the boundary math lives in exactly one
/// tested place instead of being duplicated across the downloader and writer.
public struct TorrentLayout: Sendable, Equatable {
    public let pieceLength: Int
    public let totalSize: Int64
    public let pieceCount: Int
    private let fileStarts: [Int64]
    private let fileLengths: [Int64]

    public init(metainfo: TorrentMetainfo) {
        self.pieceLength = metainfo.pieceLength
        self.totalSize = metainfo.totalSize
        self.pieceCount = metainfo.pieceHashes.count
        var starts: [Int64] = []
        starts.reserveCapacity(metainfo.files.count)
        var running: Int64 = 0
        for file in metainfo.files {
            starts.append(running)
            running += file.length
        }
        self.fileStarts = starts
        self.fileLengths = metainfo.files.map(\.length)
    }

    public var fileCount: Int { fileLengths.count }

    /// The trailing piece is shorter whenever the total size is not an exact
    /// multiple of the piece length.
    public func length(ofPiece index: Int) -> Int {
        guard pieceCount > 0 else { return 0 }
        if index == pieceCount - 1 {
            return Int(totalSize - Int64(index) * Int64(pieceLength))
        }
        return pieceLength
    }

    public func range(ofPiece index: Int) -> Range<Int64> {
        let start = Int64(index) * Int64(pieceLength)
        return start ..< start + Int64(length(ofPiece: index))
    }

    public func range(ofFile id: Int) -> Range<Int64> {
        let start = fileStarts[id]
        return start ..< start + fileLengths[id]
    }

    /// Every piece that overlaps any of the given files, including the boundary
    /// pieces a selected file shares with a deselected neighbor. Those shared
    /// pieces must be downloaded in full so the selected file's edge can be
    /// SHA-1 verified; the neighbor's slice of such a piece is incidental.
    public func pieceIndices(forFiles fileIDs: Set<Int>) -> Set<Int> {
        guard pieceLength > 0 else { return [] }
        var indices = Set<Int>()
        for id in fileIDs where id >= 0 && id < fileLengths.count {
            let range = self.range(ofFile: id)
            guard !range.isEmpty else { continue }
            let first = Int(range.lowerBound / Int64(pieceLength))
            let last = Int((range.upperBound - 1) / Int64(pieceLength))
            for piece in first...last where piece < pieceCount {
                indices.insert(piece)
            }
        }
        return indices
    }

    /// Bytes of each file (indexed by file id) already covered by the completed
    /// piece set. A file's value is clamped to its own length, so a boundary
    /// piece shared with a neighbor never over-counts.
    public func completedBytesPerFile(completedPieces: Set<Int>) -> [Int64] {
        var result = [Int64](repeating: 0, count: fileLengths.count)
        guard pieceLength > 0 else { return result }
        for piece in completedPieces where piece >= 0 && piece < pieceCount {
            let pieceRange = range(ofPiece: piece)
            var id = fileIndex(containing: pieceRange.lowerBound)
            while id < fileLengths.count {
                let fileRange = range(ofFile: id)
                if fileRange.lowerBound >= pieceRange.upperBound { break }
                let overlapLow = max(pieceRange.lowerBound, fileRange.lowerBound)
                let overlapHigh = min(pieceRange.upperBound, fileRange.upperBound)
                if overlapHigh > overlapLow {
                    result[id] += overlapHigh - overlapLow
                }
                id += 1
            }
        }
        return result
    }

    /// Index of the first file whose range contains `offset`, skipping any
    /// zero-length files that share a boundary. Binary search keeps the
    /// per-piece distribution near O(log files) instead of scanning from 0.
    private func fileIndex(containing offset: Int64) -> Int {
        guard !fileStarts.isEmpty else { return 0 }
        var low = 0
        var high = fileStarts.count - 1
        var candidate = 0
        while low <= high {
            let mid = (low + high) / 2
            if fileStarts[mid] <= offset {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // Walk back over zero-length files sharing this start so their boundary
        // slices are still considered by the caller's forward scan.
        while candidate > 0 && fileStarts[candidate - 1] == fileStarts[candidate] {
            candidate -= 1
        }
        return candidate
    }
}
