import Foundation
import os
import SwiftorrentCore

/// On-disk snapshot of the confirmed torrent list, used to restore the session
/// across app launches. Each item carries the bencoded `info` dictionary plus
/// its announce/web-seed URLs, so the full `TorrentMetainfo` can be rebuilt
/// offline (no re-resolution / network) on the next launch.
struct PersistedSession: Codable, Sendable, Equatable {
    var destinationPath: String
    var downloadRateLimit: Int?
    var items: [PersistedItem]
}

struct PersistedItem: Codable, Sendable, Equatable {
    enum Source: Codable, Sendable, Equatable {
        case torrentFile(path: String)
        case magnet(text: String)
    }

    struct File: Codable, Sendable, Equatable {
        var id: Int
        var path: String
        var totalBytes: Int64
        var downloadedBytes: Int64
        var isSelected: Bool
    }

    var id: UUID
    var name: String
    var destinationPath: String
    var source: Source
    var stripRootDirectory: Bool
    var createsEnclosingDirectory: Bool
    var outputRelativePaths: [String]
    var files: [File]
    var totalBytes: Int64
    var downloadedBytes: Int64
    var progress: Double
    var state: String
    var status: String
    /// The raw bencoded `info` dictionary, sufficient to rebuild the metainfo.
    var infoDictionaryData: Data
    var announceURLs: [String]
    var webSeedURLs: [String]
}

/// Reads and writes the persisted session JSON under Application Support. Writes
/// are serialized through the actor so a periodic checkpoint and a structural
/// change can never interleave a half-written file; reads are nonisolated and
/// only happen once at launch.
actor TorrentSessionStore {
    private let fileURL: URL
    private static let logger = Logger(subsystem: "Swiftorrent", category: "Persistence")

    init(fileURL: URL = TorrentSessionStore.defaultURL()) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Swiftorrent", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
    }

    /// Loads the snapshot synchronously. Returns `nil` when no session has been
    /// saved yet or the file is unreadable/corrupt (a bad file is ignored rather
    /// than crashing the launch).
    nonisolated func load() -> PersistedSession? {
        // A missing file just means "no session saved yet"; only a present but
        // undecodable file is worth surfacing.
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedSession.self, from: data)
        } catch {
            Self.logger.error("Failed to decode session at \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ snapshot: PersistedSession) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to persist session to \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
