import Foundation
import Observation
import SwiftorrentCore

@MainActor
@Observable
public final class TorrentSession {
    public private(set) var items: [TorrentItem] = []
    public var destination: URL

    private let metainfoParser = TorrentMetainfoParser()
    private let magnetParser = MagnetLinkParser()
    private let magnetResolver = MagnetMetadataResolver()
    private let downloader = TorrentDownloader()
    private var tasks: [TorrentItem.ID: Task<Void, Never>] = [:]
    private var metainfos: [TorrentItem.ID: TorrentMetainfo] = [:]

    public init(destination: URL = DefaultDownloadDirectory.url()) {
        self.destination = destination
    }

    public func chooseDestination(_ url: URL) {
        destination = url
    }

    public func addTorrentFile(_ url: URL) {
        let item = TorrentItem(name: url.lastPathComponent, source: .torrentFile(url), destination: destination, totalBytes: 0)
        items.insert(item, at: 0)
        tasks[item.id] = Task {
            defer { tasks[item.id] = nil }
            do {
                let data = try Data(contentsOf: url)
                try Task.checkCancellation()
                let metainfo = try metainfoParser.parse(data: data)
                metainfos[item.id] = metainfo
                update(item.id) {
                    $0.name = metainfo.name
                    $0.totalBytes = metainfo.totalSize
                    $0.outputRelativePaths = metainfo.files.map(\.path)
                    $0.files = makeFileEntries(from: metainfo, existing: $0.files)
                    $0.createsEnclosingDirectory = metainfo.createsEnclosingDirectory
                    $0.status = "Choose files to download."
                    $0.state = .reviewing
                }
            } catch is CancellationError {
                return
            } catch {
                update(item.id) {
                    $0.status = error.localizedDescription
                    $0.state = .failed
                }
            }
        }
    }

    public func addMagnet(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = TorrentItem(name: "Magnet link", source: .magnet(trimmedText), destination: destination, totalBytes: 0)
        items.insert(item, at: 0)
        tasks[item.id] = Task {
            defer { tasks[item.id] = nil }
            do {
                let magnet = try magnetParser.parse(trimmedText)
                let name = magnet.displayName ?? "Magnet \(magnet.infoHash.map { String(format: "%02x", $0) }.joined().prefix(8))"
                update(item.id) {
                    $0.name = name
                    $0.status = "Resolving metadata."
                }
                let metainfo = try await magnetResolver.resolve(magnet: magnet) { [weak self] progress in
                    await self?.update(item.id) {
                        $0.status = progress.status
                        $0.state = .downloading
                    }
                }
                metainfos[item.id] = metainfo
                update(item.id) {
                    $0.name = metainfo.name
                    $0.totalBytes = metainfo.totalSize
                    $0.outputRelativePaths = metainfo.files.map(\.path)
                    $0.files = makeFileEntries(from: metainfo, existing: $0.files)
                    $0.createsEnclosingDirectory = metainfo.createsEnclosingDirectory
                    $0.status = "Choose files to download."
                    $0.state = .reviewing
                }
            } catch is CancellationError {
                return
            } catch {
                update(item.id) {
                    $0.status = error.localizedDescription
                    $0.state = .failed
                }
            }
        }
    }

    public func remove(_ item: TorrentItem, deleteFiles: Bool = false) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        metainfos[item.id] = nil
        if deleteFiles {
            removeFiles(for: item)
        }
        items.removeAll { $0.id == item.id }
    }

    /// Toggles whether a file inside a multi-file torrent is downloaded. If the
    /// torrent is already running, its download is restarted with the new
    /// selection (on-disk pieces are re-verified, so progress is preserved).
    public func setFileSelected(itemID: TorrentItem.ID, fileID: Int, isSelected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let fileIndex = items[index].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        guard items[index].files[fileIndex].isSelected != isSelected else { return }
        items[index].files[fileIndex].isSelected = isSelected
        guard let metainfo = metainfos[itemID] else { return }
        // Only relaunch torrents that are actively working; failed/queued rows
        // pick up the new selection when they next start.
        guard items[index].state == .downloading || items[index].state == .complete else { return }
        items[index].state = .downloading
        items[index].status = "Applying file selection."
        tasks[itemID]?.cancel()
        tasks[itemID] = Task {
            defer { tasks[itemID] = nil }
            do {
                try await runDownload(itemID: itemID, metainfo: metainfo)
            } catch is CancellationError {
                return
            } catch {
                update(itemID) {
                    $0.status = error.localizedDescription
                    $0.state = .failed
                }
            }
        }
    }

    /// Confirms the user's selection from the add dialog and begins downloading.
    /// When `createSubfolder` is `false`, multi-file torrents are flattened so
    /// their files land directly in the destination instead of an enclosing
    /// `<name>/` folder.
    public func startDownload(itemID: TorrentItem.ID, createSubfolder: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .reviewing,
              var metainfo = metainfos[itemID] else {
            return
        }
        guard items[index].files.contains(where: \.isSelected) else { return }

        if !createSubfolder {
            metainfo = metainfo.flatteningRootDirectory()
            metainfos[itemID] = metainfo
            items[index].outputRelativePaths = metainfo.files.map(\.path)
            items[index].files = makeFileEntries(from: metainfo, existing: items[index].files)
            items[index].createsEnclosingDirectory = false
        }

        items[index].state = .downloading
        items[index].status = "Starting download."
        tasks[itemID] = Task {
            defer { tasks[itemID] = nil }
            do {
                try await runDownload(itemID: itemID, metainfo: metainfo)
            } catch is CancellationError {
                return
            } catch {
                update(itemID) {
                    $0.status = error.localizedDescription
                    $0.state = .failed
                }
            }
        }
    }

    /// Selects or deselects every file in a torrent at once (the dialog's
    /// "Select All" / "Deselect All" actions).
    public func setAllFilesSelected(itemID: TorrentItem.ID, isSelected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        for fileIndex in items[index].files.indices {
            items[index].files[fileIndex].isSelected = isSelected
        }
    }

    private func removeFiles(for item: TorrentItem) {
        let destination = item.destination.standardizedFileURL
        let relativePaths = item.outputRelativePaths.isEmpty ? [item.name] : item.outputRelativePaths
        for relativePath in relativePaths {
            let finalURL = destination.appendingPathComponent(relativePath).standardizedFileURL
            let partialURL = finalURL.appendingPathExtension("tor").standardizedFileURL
            removeFileIfContained(partialURL, in: destination)
            removeFileIfContained(finalURL, in: destination)
        }
        pruneEmptyDirectories(for: relativePaths, in: destination)
    }

    private func removeFileIfContained(_ url: URL, in destination: URL) {
        let destinationPath = destination.path
        let path = url.path
        guard path == destinationPath || path.hasPrefix(destinationPath + "/") else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func pruneEmptyDirectories(for relativePaths: [String], in destination: URL) {
        let directories = Set(relativePaths.map { path in
            destination.appendingPathComponent(path).deletingLastPathComponent().standardizedFileURL
        })
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            var current = directory
            while current.path.hasPrefix(destination.path + "/"), current != destination {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path), contents.isEmpty else {
                    break
                }
                try? FileManager.default.removeItem(at: current)
                current.deleteLastPathComponent()
            }
        }
    }

    private func runDownload(itemID: TorrentItem.ID, metainfo: TorrentMetainfo) async throws {
        let selected = selectedFileIDs(for: itemID, metainfo: metainfo)
        let itemDestination = items.first(where: { $0.id == itemID })?.destination ?? destination
        try await downloader.download(metainfo: metainfo, destination: itemDestination, selectedFileIDs: selected) { [weak self] progress in
            await self?.update(itemID) { item in
                item.status = progress.status
                item.totalBytes = progress.totalBytes
                item.downloadedBytes = progress.downloadedBytes
                item.progress = progress.fractionCompleted
                item.applyFileProgress(progress.files)
                if progress.fractionCompleted >= 1 {
                    item.state = .complete
                } else {
                    item.state = .downloading
                }
            }
        }
    }

    private func selectedFileIDs(for itemID: TorrentItem.ID, metainfo: TorrentMetainfo) -> Set<Int> {
        guard let item = items.first(where: { $0.id == itemID }), !item.files.isEmpty else {
            return Set(metainfo.files.map(\.id))
        }
        return Set(item.files.filter(\.isSelected).map(\.id))
    }

    private func makeFileEntries(from metainfo: TorrentMetainfo, existing: [TorrentItem.FileEntry]) -> [TorrentItem.FileEntry] {
        // Preserve any selection the user already toggled before metadata
        // finished resolving (magnet path populates files late).
        let selectionByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.isSelected) })
        return metainfo.files.map { file in
            TorrentItem.FileEntry(
                id: file.id,
                path: file.path,
                totalBytes: file.length,
                downloadedBytes: 0,
                isSelected: selectionByID[file.id] ?? true
            )
        }
    }

    private func update(_ id: TorrentItem.ID, mutate: (inout TorrentItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }
}

public struct TorrentItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case torrentFile(URL)
        case magnet(String)
    }

    public enum State: String, Equatable, Sendable {
        case queued
        case reviewing
        case downloading
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
    public var downloadedBytes: Int64
    public var progress: Double
    public var status: String
    public var state: State

    public init(name: String, source: Source, destination: URL, totalBytes: Int64) {
        self.id = UUID()
        self.name = name
        self.source = source
        self.destination = destination
        self.totalBytes = totalBytes
        self.outputRelativePaths = []
        self.files = []
        self.createsEnclosingDirectory = false
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

public enum DefaultDownloadDirectory {
    public static func url() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}
