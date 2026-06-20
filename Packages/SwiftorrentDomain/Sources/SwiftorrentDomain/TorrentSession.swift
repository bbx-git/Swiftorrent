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
                update(item.id) {
                    $0.name = metainfo.name
                    $0.totalBytes = metainfo.totalSize
                    $0.outputRelativePaths = metainfo.files.map(\.path)
                    $0.status = "Starting download."
                }
                try await start(itemID: item.id, metainfo: metainfo)
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
                update(item.id) {
                    $0.name = metainfo.name
                    $0.totalBytes = metainfo.totalSize
                    $0.outputRelativePaths = metainfo.files.map(\.path)
                    $0.status = "Metadata resolved. Starting download."
                }
                try await start(itemID: item.id, metainfo: metainfo)
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
        if deleteFiles {
            removeFiles(for: item)
        }
        items.removeAll { $0.id == item.id }
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

    private func start(itemID: TorrentItem.ID, metainfo: TorrentMetainfo) async throws {
        try await downloader.download(metainfo: metainfo, destination: destination) { [weak self] progress in
            await self?.update(itemID) { item in
                item.status = progress.status
                item.totalBytes = progress.totalBytes
                item.downloadedBytes = progress.downloadedBytes
                item.progress = progress.fractionCompleted
                if progress.fractionCompleted >= 1 {
                    item.state = .complete
                } else {
                    item.state = .downloading
                }
            }
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
        case downloading
        case complete
        case failed
    }

    public let id: UUID
    public var name: String
    public var source: Source
    public var destination: URL
    public var totalBytes: Int64
    public var outputRelativePaths: [String]
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
}

public enum DefaultDownloadDirectory {
    public static func url() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}
