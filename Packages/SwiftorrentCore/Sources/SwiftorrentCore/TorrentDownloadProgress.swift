import Foundation

/// Per-file progress within a torrent download.
public struct TorrentFileProgress: Sendable, Identifiable, Equatable {
    public let id: Int
    public let path: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let isSelected: Bool

    public init(id: Int, path: String, downloadedBytes: Int64, totalBytes: Int64, isSelected: Bool) {
        self.id = id
        self.path = path
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isSelected = isSelected
    }
}

/// A single progress update emitted during a download: a status line, the
/// overall byte totals, and an optional per-file breakdown.
public struct TorrentDownloadProgress: Sendable {
    public let status: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    /// Per-file breakdown. Empty means "no change since the last update" so the
    /// frequent status-only ticks (connecting, contacting trackers) don't have
    /// to recompute the whole table; consumers keep the last non-empty value.
    public let files: [TorrentFileProgress]

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public init(status: String, downloadedBytes: Int64, totalBytes: Int64, files: [TorrentFileProgress] = []) {
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.files = files
    }
}
