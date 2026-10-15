import Foundation
import SwiftorrentCore

public struct TorrentItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case torrentFile(URL)
        case magnet(String)
    }

    public enum State: String, Equatable, Sendable {
        case queued
        case reviewing
        case downloading
        case paused
        case complete
        case failed
    }

    public struct FileEntry: Identifiable, Equatable, Sendable {
        public let id: Int
        public let path: String
        public let totalBytes: Int64
        public var downloadedBytes: Int64
        public var isSelected: Bool

        public init(id: Int, path: String, totalBytes: Int64, downloadedBytes: Int64 = 0, isSelected: Bool = true) {
            self.id = id
            self.path = path
            self.totalBytes = totalBytes
            self.downloadedBytes = downloadedBytes
            self.isSelected = isSelected
        }

        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
        }

        public var name: String {
            (path as NSString).lastPathComponent
        }

        public var totalDescription: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
    }

    public let id: UUID
    public var name: String
    public var source: Source
    public var destination: URL
    public var totalBytes: Int64
    public var outputRelativePaths: [String]
    public var files: [FileEntry]
    public var createsEnclosingDirectory: Bool
    /// Whether the shared top-level torrent folder is stripped from on-disk
    /// output paths (the "don't create a subfolder" choice from the add dialog).
    public var stripRootDirectory: Bool
    public var downloadedBytes: Int64
    public var progress: Double
    public var status: String
    public var state: State
    /// Live download rate for this torrent in bytes per second. Transient
    /// (sampled once a second by the session, never persisted); it is 0 unless
    /// the torrent is actively downloading.
    public var downloadSpeed: Int64 = 0
    /// Verified bytes plus blocks received for pieces still assembling. Transient
    /// like `downloadSpeed`; the speed is derived from it, the progress bar is not.
    public var liveBytes: Int64 = 0

    public init(name: String, source: Source, destination: URL, totalBytes: Int64) {
        self.id = UUID()
        self.name = name
        self.source = source
        self.destination = destination
        self.totalBytes = totalBytes
        self.outputRelativePaths = []
        self.files = []
        self.createsEnclosingDirectory = false
        self.stripRootDirectory = false
        self.downloadedBytes = 0
        self.progress = 0
        self.status = "Queued"
        self.state = .queued
    }

    public static func failed(name: String, message: String, destination: URL) -> TorrentItem {
        var item = TorrentItem(name: name, source: .magnet(""), destination: destination, totalBytes: 0)
        item.status = message
        item.state = .failed
        return item
    }

    public var downloadedDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    /// This torrent's live download rate formatted for display, e.g. "1.2 MB/s".
    public var speedDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadSpeed, countStyle: .file) + "/s"
    }

    public var totalDescription: String {
        totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) : "Unknown"
    }

    /// Folds a downloader per-file snapshot into the existing entries. An empty
    /// snapshot means "unchanged" so frequent status-only ticks don't clobber
    /// the table; user-driven `isSelected` is always preserved.
    mutating func applyFileProgress(_ snapshot: [TorrentFileProgress]) {
        guard !snapshot.isEmpty else { return }
        let bytesByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.downloadedBytes) })
        for index in files.indices {
            if let bytes = bytesByID[files[index].id] {
                files[index].downloadedBytes = bytes
            }
        }
    }
}
