import Foundation
import SwiftorrentCore

extension TorrentSession {
    /// Rebuilds the confirmed list from a saved snapshot. Each item's metainfo is
    /// reconstructed offline from its stored `info` dictionary; items whose
    /// metainfo can't be rebuilt are dropped rather than restored broken.
    func restore(_ snapshot: PersistedSession) {
        for persisted in snapshot.items {
            guard let (item, metainfo) = restoreItem(persisted) else { continue }
            metainfos[item.id] = metainfo
            items.append(item)
        }
    }

    private func restoreItem(_ persisted: PersistedItem) -> (TorrentItem, TorrentMetainfo)? {
        let announceURLs = persisted.announceURLs.compactMap { URL(string: $0) }
        let webSeedURLs = persisted.webSeedURLs.compactMap { URL(string: $0) }
        let metainfo: TorrentMetainfo
        do {
            metainfo = try metainfoParser.parseInfoDictionary(
                data: persisted.infoDictionaryData,
                announceURLs: announceURLs,
                webSeedURLs: webSeedURLs,
                preferredName: persisted.name
            )
        } catch {
            logger.error("Dropping restored row \"\(persisted.name, privacy: .private)\": stored info dict failed to parse: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let source: TorrentItem.Source = switch persisted.source {
        case let .torrentFile(path): .torrentFile(URL(fileURLWithPath: path))
        case let .magnet(text): .magnet(text)
        }
        var item = TorrentItem(
            name: persisted.name,
            source: source,
            destination: URL(fileURLWithPath: persisted.destinationPath, isDirectory: true),
            totalBytes: persisted.totalBytes
        )
        item.outputRelativePaths = persisted.outputRelativePaths
        item.files = persisted.files.map {
            TorrentItem.FileEntry(id: $0.id, path: $0.path, totalBytes: $0.totalBytes, downloadedBytes: $0.downloadedBytes, isSelected: $0.isSelected)
        }
        item.createsEnclosingDirectory = persisted.createsEnclosingDirectory
        item.stripRootDirectory = persisted.stripRootDirectory
        item.downloadedBytes = persisted.downloadedBytes
        item.progress = persisted.progress
        item.status = persisted.status
        item.state = TorrentItem.State(rawValue: persisted.state) ?? .paused
        return (item, metainfo)
    }

    /// Auto-resumes torrents that were actively downloading when the app last
    /// quit. Paused/complete/failed rows keep their restored state.
    func resumeRestoredDownloads() {
        for item in items where item.state == .downloading {
            guard let metainfo = metainfos[item.id] else { continue }
            update(item.id) { $0.status = "Resuming download." }
            launchDownloadTask(itemID: item.id, metainfo: metainfo)
        }
    }

    /// Serializes the current confirmed list to disk off the main actor. Only
    /// items with a known metainfo are saved (so they can be rebuilt on launch).
    func persist() {
        let snapshot = currentSnapshot()
        let store = self.store
        Task { await store.save(snapshot) }
    }

    private func currentSnapshot() -> PersistedSession {
        PersistedSession(
            destinationPath: destination.path(percentEncoded: false),
            downloadRateLimit: downloadRateLimit,
            items: items.compactMap { item in
                guard let metainfo = metainfos[item.id] else { return nil }
                return PersistedItem(
                    id: item.id,
                    name: item.name,
                    destinationPath: item.destination.path(percentEncoded: false),
                    source: persistedSource(item.source),
                    stripRootDirectory: item.stripRootDirectory,
                    createsEnclosingDirectory: item.createsEnclosingDirectory,
                    outputRelativePaths: item.outputRelativePaths,
                    files: item.files.map {
                        PersistedItem.File(id: $0.id, path: $0.path, totalBytes: $0.totalBytes, downloadedBytes: $0.downloadedBytes, isSelected: $0.isSelected)
                    },
                    totalBytes: item.totalBytes,
                    downloadedBytes: item.downloadedBytes,
                    progress: item.progress,
                    state: item.state.rawValue,
                    status: item.status,
                    infoDictionaryData: metainfo.infoDictionaryData,
                    announceURLs: metainfo.announceURLs.map(\.absoluteString),
                    webSeedURLs: metainfo.webSeedURLs.map(\.absoluteString)
                )
            }
        )
    }

    private func persistedSource(_ source: TorrentItem.Source) -> PersistedItem.Source {
        switch source {
        case let .torrentFile(url): .torrentFile(path: url.path(percentEncoded: false))
        case let .magnet(text): .magnet(text: text)
        }
    }
}
