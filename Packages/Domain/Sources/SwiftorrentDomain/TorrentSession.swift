import Foundation
import Observation
import os
import SwiftorrentCore

@MainActor
@Observable
public final class TorrentSession {
    /// Torrents the user has confirmed; these are the rows shown in the list.
    public internal(set) var items: [TorrentItem] = []
    /// Torrents still being resolved or awaiting file selection in the add
    /// dialog. They are kept out of `items` so a torrent only appears in the
    /// list once the user clicks Download.
    public internal(set) var pendingItems: [TorrentItem] = []
    public var destination: URL
    /// Combined download speed across all torrents, in bytes per second. Sampled
    /// once a second from the change in total bytes on disk.
    public internal(set) var downloadSpeed: Int64 = 0
    /// Combined download throughput cap in bytes per second, or `nil` for
    /// unlimited. Applied across every active download and persisted.
    public var downloadRateLimit: Int? {
        didSet {
            guard downloadRateLimit != oldValue else { return }
            let limit = downloadRateLimit
            Task { await rateLimiter.setLimit(bytesPerSecond: limit) }
            persist()
        }
    }

    @ObservationIgnored let logger = Logger(subsystem: "Swiftorrent", category: "Session")
    let metainfoParser = TorrentMetainfoParser()
    private let magnetParser = MagnetLinkParser()
    private let magnetResolver = MagnetMetadataResolver()
    private let rateLimiter = RateLimiter()
    let downloader: TorrentDownloader
    let store: TorrentSessionStore
    var tasks: [TorrentItem.ID: Task<Void, Never>] = [:]
    var metainfos: [TorrentItem.ID: TorrentMetainfo] = [:]
    var speedSampler: Task<Void, Never>?
    var checkpointTick = 0

    public convenience init(destination: URL = DefaultDownloadDirectory.url()) {
        self.init(destination: destination, store: TorrentSessionStore())
    }

    init(destination: URL = DefaultDownloadDirectory.url(), store: TorrentSessionStore) {
        self.store = store
        self.downloader = TorrentDownloader(rateLimiter: rateLimiter)
        // Restore the previous session (if any) before the UI observes us, so the
        // list and rate limit come back populated. Reconstructing each metainfo
        // from its stored `info` dictionary needs no network.
        let snapshot = store.load()
        self.destination = snapshot.map { URL(fileURLWithPath: $0.destinationPath, isDirectory: true) } ?? destination
        self.downloadRateLimit = snapshot?.downloadRateLimit
        if let snapshot { restore(snapshot) }
        let limit = downloadRateLimit
        Task { await rateLimiter.setLimit(bytesPerSecond: limit) }
        startSpeedSampler()
        resumeRestoredDownloads()
    }

    public func chooseDestination(_ url: URL) {
        destination = url
        persist()
    }

    @discardableResult
    public func addTorrentFile(_ url: URL) -> TorrentItem.ID {
        var item = TorrentItem(name: url.lastPathComponent, source: .torrentFile(url), destination: destination, totalBytes: 0)
        item.status = "Reading torrent…"
        let id = item.id
        pendingItems.append(item)
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                // This task inherits the main actor; read and parse the file off it
                // so a large torrent (tens of thousands of files) cannot stall the UI.
                let parser = metainfoParser
                let metainfo = try await Task.detached(priority: .userInitiated) {
                    try parser.parse(data: Data(contentsOf: url))
                }.value
                try Task.checkCancellation()
                metainfos[id] = metainfo
                applyResolvedMetadata(metainfo, to: id)
            } catch is CancellationError {
                return
            } catch {
                failPending(id, message: error.localizedDescription)
            }
        }
        return id
    }

    @discardableResult
    public func addMagnet(_ text: String) -> TorrentItem.ID {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var item = TorrentItem(name: "Magnet link", source: .magnet(trimmedText), destination: destination, totalBytes: 0)
        item.status = "Resolving metadata…"
        let id = item.id
        pendingItems.append(item)
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                let magnet = try magnetParser.parse(trimmedText)
                let name = magnet.displayName ?? "Magnet \(magnet.infoHash.map { String(format: "%02x", $0) }.joined().prefix(8))"
                update(id) {
                    $0.name = name
                    $0.status = "Resolving metadata…"
                }
                let metainfo = try await magnetResolver.resolve(magnet: magnet) { progress in
                    await self.update(id) {
                        $0.status = progress.status
                    }
                }
                metainfos[id] = metainfo
                applyResolvedMetadata(metainfo, to: id)
            } catch is CancellationError {
                return
            } catch {
                failPending(id, message: error.localizedDescription)
            }
        }
        return id
    }

    public func remove(_ item: TorrentItem, deleteFiles: Bool = false) {
        let task = tasks[item.id]
        task?.cancel()
        tasks[item.id] = nil
        metainfos[item.id] = nil
        if deleteFiles {
            // Cancellation is cooperative and the writer recreates paths on every
            // write, so deleting now could be undone by the task's last write.
            Task { await removeFiles(for: item, after: task) }
        }
        items.removeAll { $0.id == item.id }
        pendingItems.removeAll { $0.id == item.id }
        persist()
    }

    /// Cancels every running download and resolve and waits for them to wind
    /// down (each sends its final tracker announce). Rows keep their state, so
    /// the next launch resumes them. Used when the app quits.
    public func stopAll() async {
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    /// Whether any row in the list has finished downloading.
    public var hasCompleted: Bool {
        items.contains { $0.state == .complete }
    }

    /// Removes every completed torrent from the list. Files stay on disk, and
    /// paused, failed and active rows are untouched.
    public func removeCompleted() {
        for item in items where item.state == .complete {
            remove(item)
        }
    }

    /// Discards a torrent still in the add dialog (resolution failed, or the user
    /// dismissed the dialog without starting). Nothing was written to disk yet.
    /// A no-op for anything not in `pendingItems`: once `startDownload` moves the
    /// item into `items`, `tasks[itemID]` holds the live download task, so the
    /// add window's catch-all `.onDisappear` cancel must not touch it.
    public func cancelPending(itemID: TorrentItem.ID) {
        guard pendingItems.contains(where: { $0.id == itemID }) else { return }
        tasks[itemID]?.cancel()
        tasks[itemID] = nil
        metainfos[itemID] = nil
        pendingItems.removeAll { $0.id == itemID }
    }

    /// Confirms the user's selection from the add dialog, moves the torrent into
    /// the visible list, and begins downloading. When `createSubfolder` is
    /// `false`, multi-file torrents write their files directly into the
    /// destination instead of an enclosing `<name>/` folder.
    public func startDownload(itemID: TorrentItem.ID, createSubfolder: Bool) {
        guard let pendingIndex = pendingItems.firstIndex(where: { $0.id == itemID }),
              pendingItems[pendingIndex].state == .reviewing,
              let metainfo = metainfos[itemID] else {
            return
        }
        var item = pendingItems.remove(at: pendingIndex)
        guard item.files.contains(where: \.isSelected) else {
            // Nothing selected: drop the torrent rather than starting a no-op.
            metainfos[itemID] = nil
            return
        }

        let stripRoot = !createSubfolder && metainfo.createsEnclosingDirectory
        item.stripRootDirectory = stripRoot
        item.createsEnclosingDirectory = stripRoot ? false : metainfo.createsEnclosingDirectory
        // `outputRelativePaths` drives on-disk deletion, so it must match where
        // files actually land (stripped of the root folder when requested).
        item.outputRelativePaths = stripRoot
            ? metainfo.flatteningRootDirectory().files.map(\.path)
            : metainfo.files.map(\.path)
        item.state = .downloading
        item.status = "Starting download."
        items.insert(item, at: 0)
        persist()

        launchDownloadTask(itemID: itemID, metainfo: metainfo)
    }

    /// Cancels the running download task while keeping the torrent (and its
    /// on-disk progress) in the list, so it can be resumed later.
    public func pause(itemID: TorrentItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .downloading else {
            return
        }
        tasks[itemID]?.cancel()
        tasks[itemID] = nil
        items[index].state = .paused
        items[index].status = "Paused."
        persist()
    }

    /// Restarts a paused or failed torrent. On-disk pieces are re-verified, so the
    /// download picks up where it left off — this is also the retry path for a
    /// torrent that failed mid-download (e.g. a dropped connection).
    public func resume(itemID: TorrentItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .paused || items[index].state == .failed,
              let metainfo = metainfos[itemID] else {
            return
        }
        items[index].state = .downloading
        items[index].status = "Resuming download."
        persist()
        launchDownloadTask(itemID: itemID, metainfo: metainfo)
    }

    /// Spawns the download task for a torrent already in `items`, routing
    /// failures into the item's `failed` state. Shared by start, resume, and
    /// file-selection relaunch so they stay in lockstep.
    func launchDownloadTask(itemID: TorrentItem.ID, metainfo: TorrentMetainfo) {
        tasks[itemID] = Task {
            defer { tasks[itemID] = nil }
            do {
                try await runDownload(itemID: itemID, metainfo: metainfo)
            } catch is CancellationError {
                return
            } catch {
                // A cancelled download (pause / relaunch / remove) tears down its
                // socket, which can surface as a network/timeout error rather than
                // CancellationError. Don't misreport that as a failure — the
                // pause/relaunch path already set the correct state.
                if Task.isCancelled { return }
                update(itemID) {
                    $0.status = error.localizedDescription
                    $0.state = .failed
                }
                persist()
            }
        }
    }

    private func applyResolvedMetadata(_ metainfo: TorrentMetainfo, to id: TorrentItem.ID) {
        update(id) {
            $0.name = metainfo.name
            $0.totalBytes = metainfo.totalSize
            $0.outputRelativePaths = metainfo.files.map(\.path)
            $0.files = makeFileEntries(from: metainfo, existing: $0.files)
            $0.createsEnclosingDirectory = metainfo.createsEnclosingDirectory
            $0.status = "Choose files to download."
            $0.state = .reviewing
        }
    }

    private func failPending(_ id: TorrentItem.ID, message: String) {
        // A torrent that never resolved was never shown in the list; surface the
        // error in the dialog by keeping it pending in a failed state.
        update(id) {
            $0.status = message
            $0.state = .failed
        }
    }

    private func runDownload(itemID: TorrentItem.ID, metainfo: TorrentMetainfo) async throws {
        let selected = selectedFileIDs(for: itemID, metainfo: metainfo)
        let item = items.first(where: { $0.id == itemID })
        let itemDestination = item?.destination ?? destination
        let stripRoot = item?.stripRootDirectory ?? false
        try await downloader.download(metainfo: metainfo, destination: itemDestination, selectedFileIDs: selected, stripRootDirectory: stripRoot) { [weak self] progress in
            await self?.applyDownloadProgress(progress, to: itemID)
        }
    }

    /// Folds a downloader progress tick into the item, and persists once when the
    /// torrent first reaches completion (a completed row isn't re-launched, so its
    /// final state must be saved). Routine ticks are persisted by the periodic
    /// checkpoint instead of on every update.
    private func applyDownloadProgress(_ progress: TorrentDownloadProgress, to itemID: TorrentItem.ID) {
        // Cancellation is cooperative, so a paused torrent's download task can emit
        // one final tick after `pause()` has already set `.paused`. Drop ticks for
        // anything that isn't actively downloading, otherwise the late tick reverts
        // the row to `.downloading` and rewinds the progress bar to its value.
        guard items.first(where: { $0.id == itemID })?.state == .downloading else { return }
        var justCompleted = false
        update(itemID) { item in
            let wasComplete = item.state == .complete
            item.status = progress.status
            item.totalBytes = progress.totalBytes
            item.downloadedBytes = progress.downloadedBytes
            item.liveBytes = progress.liveBytes
            item.progress = progress.fractionCompleted
            item.applyFileProgress(progress.files)
            item.state = progress.fractionCompleted >= 1 ? .complete : .downloading
            justCompleted = !wasComplete && item.state == .complete
        }
        if justCompleted { persist() }
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

    /// Mutates an item in whichever list (`items` or `pendingItems`) holds it.
    func update(_ id: TorrentItem.ID, mutate: (inout TorrentItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            mutate(&items[index])
        } else if let index = pendingItems.firstIndex(where: { $0.id == id }) {
            mutate(&pendingItems[index])
        }
    }

}
