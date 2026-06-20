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

    public init(destination: URL = DefaultDownloadDirectory.url()) {
        self.destination = destination
    }

    public func chooseDestination(_ url: URL) {
        destination = url
    }

    public func addTorrentFile(_ url: URL) {
        Task {
            do {
                let data = try Data(contentsOf: url)
                let metainfo = try metainfoParser.parse(data: data)
                let item = TorrentItem(name: metainfo.name, source: .torrentFile(url), destination: destination, totalBytes: metainfo.totalSize)
                items.insert(item, at: 0)
                try await start(itemID: item.id, metainfo: metainfo)
            } catch {
                items.insert(TorrentItem.failed(name: url.lastPathComponent, message: error.localizedDescription, destination: destination), at: 0)
            }
        }
    }

    public func addMagnet(_ text: String) {
        Task {
            var pendingItemID: TorrentItem.ID?
            do {
                let magnet = try magnetParser.parse(text)
                let name = magnet.displayName ?? "Magnet \(magnet.infoHash.map { String(format: "%02x", $0) }.joined().prefix(8))"
                let item = TorrentItem(name: name, source: .magnet(text), destination: destination, totalBytes: 0)
                pendingItemID = item.id
                items.insert(item, at: 0)
                let metainfo = try await magnetResolver.resolve(magnet: magnet) { [weak self] progress in
                    await self?.update(item.id) {
                        $0.status = progress.status
                        $0.state = .downloading
                    }
                }
                update(item.id) {
                    $0.name = metainfo.name
                    $0.totalBytes = metainfo.totalSize
                    $0.status = "Metadata resolved. Starting download."
                }
                try await start(itemID: item.id, metainfo: metainfo)
            } catch {
                if let pendingItemID {
                    update(pendingItemID) {
                        $0.status = error.localizedDescription
                        $0.state = .failed
                    }
                } else {
                    items.insert(TorrentItem.failed(name: "Magnet link", message: error.localizedDescription, destination: destination), at: 0)
                }
            }
        }
    }

    public func remove(_ item: TorrentItem) {
        items.removeAll { $0.id == item.id }
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
