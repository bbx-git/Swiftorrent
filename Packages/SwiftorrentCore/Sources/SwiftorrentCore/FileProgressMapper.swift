import Foundation

/// Maps a flat per-file byte tally into `[TorrentFileProgress]` rows, clamping
/// each file to its length and marking which files are part of the current
/// selection. Shared by the web-seed and peer-swarm download paths so they emit
/// identical per-file progress without each recomputing the mapping.
struct FileProgressMapper: Sendable {
    let metainfo: TorrentMetainfo
    let selection: Set<Int>

    func snapshot(perFileBytes: [Int64]) -> [TorrentFileProgress] {
        metainfo.files.map { file in
            let done = file.id < perFileBytes.count ? min(perFileBytes[file.id], file.length) : 0
            return TorrentFileProgress(
                id: file.id,
                path: file.path,
                downloadedBytes: done,
                totalBytes: file.length,
                isSelected: selection.contains(file.id)
            )
        }
    }

    /// A snapshot with every file at zero bytes downloaded.
    func empty() -> [TorrentFileProgress] {
        snapshot(perFileBytes: [Int64](repeating: 0, count: metainfo.files.count))
    }
}
