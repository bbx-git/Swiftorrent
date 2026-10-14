import Foundation
import Observation
import os
import SwiftorrentCore

@MainActor
@Observable
public final class TorrentSession {
    /// Torrents the user has confirmed; these are the rows shown in the list.
    public private(set) var items: [TorrentItem] = []
    /// Torrents still being resolved or awaiting file selection in the add
    /// dialog. They are kept out of `items` so a torrent only appears in the
    /// list once the user clicks Download.
    public private(set) var pendingItems: [TorrentItem] = []
    public var destination: URL
    /// Combined download speed across all torrents, in bytes per second. Sampled
    /// once a second from the change in total bytes on disk.
    public private(set) var downloadSpeed: Int64 = 0
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

    @ObservationIgnored private let logger = Logger(subsystem: "Swiftorrent", category: "Session")
    private let metainfoParser = TorrentMetainfoParser()
    private let magnetParser = MagnetLinkParser()
    private let magnetResolver = MagnetMetadataResolver()
    private let rateLimiter = RateLimiter()
    private let downloader: TorrentDownloader
    private let store: TorrentSessionStore
    private var tasks: [TorrentItem.ID: Task<Void, Never>] = [:]
    private var metainfos: [TorrentItem.ID: TorrentMetainfo] = [:]
    private var speedSampler: Task<Void, Never>?
    private var checkpointTick = 0

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

    /// Total bytes downloaded across every torrent currently in the list.
    private var totalDownloadedBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.downloadedBytes }
    }

    /// Combined download speed formatted for display, e.g. "1.2 MB/s".
    public var downloadSpeedDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadSpeed, countStyle: .file) + "/s"
    }

    /// Samples the combined download rate once a second. Using the delta of total
    /// bytes on disk means completed or removed torrents naturally stop counting,
    /// and a transient drop (a removed torrent) clamps to zero rather than going
    /// negative.
    private func startSpeedSampler() {
        speedSampler = Task { [weak self] in
            let clock = ContinuousClock()
            // Trailing window of (time, cumulative bytes) samples. Reporting the
            // delta across the whole window — divided by the *actual* elapsed time
            // rather than assuming an exact 1s tick — smooths the lumpiness of
            // piece-granular accounting (bytes land only when a whole piece
            // verifies), so the readout tracks the true rate instead of swinging
            // between a near-zero dip and a one-piece spike.
            var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []
            // Per-torrent trailing windows, keyed by item id, feeding the per-row
            // rate with the same smoothing as the combined figure.
            var itemWindows: [TorrentItem.ID: [(time: ContinuousClock.Instant, bytes: Int64)]] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = clock.now
                let current = self.totalDownloadedBytes
                samples.append((now, current))
                // Keep ~4 seconds of history (the most recent 4 one-second ticks).
                if samples.count > 4 { samples.removeFirst() }
                let oldest = samples[0]
                let span = oldest.time.duration(to: now)
                let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
                let delta = max(0, current - oldest.bytes)
                self.downloadSpeed = seconds > 0 ? Int64(Double(delta) / seconds) : 0
                self.updatePerItemSpeeds(now: now, windows: &itemWindows)
                // Checkpoint progress to disk every ~10s so a crash mid-download
                // loses at most a few seconds of progress (resume re-verifies the
                // actual on-disk bytes regardless).
                self.checkpointTick += 1
                if self.checkpointTick >= 10, !self.items.isEmpty {
                    self.checkpointTick = 0
                    self.persist()
                }
            }
        }
    }

    /// Updates each active torrent's per-row rate using the same trailing window
    /// as the combined figure. Torrents that aren't downloading report 0 and drop
    /// their history so a paused or finished row never shows a stale rate.
    private func updatePerItemSpeeds(
        now: ContinuousClock.Instant,
        windows: inout [TorrentItem.ID: [(time: ContinuousClock.Instant, bytes: Int64)]]
    ) {
        var live = Set<TorrentItem.ID>()
        for index in items.indices {
            guard items[index].state == .downloading else {
                if items[index].downloadSpeed != 0 { items[index].downloadSpeed = 0 }
                continue
            }
            let id = items[index].id
            live.insert(id)
            var window = windows[id] ?? []
            window.append((now, items[index].downloadedBytes))
            if window.count > 4 { window.removeFirst() }
            windows[id] = window
            let oldest = window[0]
            let span = oldest.time.duration(to: now)
            let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
            let delta = max(0, items[index].downloadedBytes - oldest.bytes)
            items[index].downloadSpeed = seconds > 0 ? Int64(Double(delta) / seconds) : 0
        }
        // Forget windows for rows that vanished or stopped downloading.
        windows = windows.filter { live.contains($0.key) }
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
                let metainfo = try await magnetResolver.resolve(magnet: magnet) { [weak self] progress in
                    await self?.update(id) {
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
    private func launchDownloadTask(itemID: TorrentItem.ID, metainfo: TorrentMetainfo) {
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

    /// Toggles whether a file inside a multi-file torrent is downloaded. Used both
    /// by the add dialog (pending review) and mid-download. A running torrent is
    /// restarted with the new selection (on-disk pieces are re-verified, so
    /// progress is preserved).
    public func setFileSelected(itemID: TorrentItem.ID, fileID: Int, isSelected: Bool) {
        if let pendingIndex = pendingItems.firstIndex(where: { $0.id == itemID }) {
            guard let fileIndex = pendingItems[pendingIndex].files.firstIndex(where: { $0.id == fileID }) else { return }
            pendingItems[pendingIndex].files[fileIndex].isSelected = isSelected
            return
        }

        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let fileIndex = items[index].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        guard items[index].files[fileIndex].isSelected != isSelected else { return }
        items[index].files[fileIndex].isSelected = isSelected
        persist()
        guard let metainfo = metainfos[itemID] else { return }
        // Only relaunch torrents that are actively working; failed rows pick up
        // the new selection when they next start.
        guard items[index].state == .downloading || items[index].state == .complete else { return }
        items[index].state = .downloading
        items[index].status = "Applying file selection."
        tasks[itemID]?.cancel()
        launchDownloadTask(itemID: itemID, metainfo: metainfo)
    }

    /// Selects or deselects every file in a torrent at once (the dialog's
    /// "Select All" / "Deselect All" actions).
    public func setAllFilesSelected(itemID: TorrentItem.ID, isSelected: Bool) {
        if let pendingIndex = pendingItems.firstIndex(where: { $0.id == itemID }) {
            for fileIndex in pendingItems[pendingIndex].files.indices {
                pendingItems[pendingIndex].files[fileIndex].isSelected = isSelected
            }
            return
        }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        for fileIndex in items[index].files.indices {
            items[index].files[fileIndex].isSelected = isSelected
        }
        persist()
    }

    /// Permanently deletes one file of a torrent from disk (its final file and
    /// any `.tor` partial), then drops it from the selection so it isn't
    /// refetched. A running download is relaunched to stop fetching it; an idle
    /// torrent (complete/paused/failed) just loses the file. The torrent's other
    /// files are untouched.
    public func deleteFile(itemID: TorrentItem.ID, fileID: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let fileIndex = items[index].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        deleteFileFromDisk(items[index].files[fileIndex], in: items[index])
        items[index].files[fileIndex].isSelected = false
        items[index].files[fileIndex].downloadedBytes = 0
        recomputeTotals(itemIndex: index)
        persist()

        // A live download must be relaunched so its piece scheduler drops the
        // now-deselected file; idle torrents simply keep the smaller selection.
        if items[index].state == .downloading, let metainfo = metainfos[itemID] {
            items[index].status = "Applying file selection."
            tasks[itemID]?.cancel()
            launchDownloadTask(itemID: itemID, metainfo: metainfo)
        }
    }

    private func deleteFileFromDisk(_ file: TorrentItem.FileEntry, in item: TorrentItem) {
        let destination = item.destination.standardizedFileURL
        // `outputRelativePaths` already accounts for the strip-root choice and is
        // indexed by file id; fall back to the torrent-relative path if missing.
        let relativePath = file.id < item.outputRelativePaths.count ? item.outputRelativePaths[file.id] : file.path
        let finalURL = destination.appendingPathComponent(relativePath).standardizedFileURL
        let partialURL = finalURL.appendingPathExtension("tor").standardizedFileURL
        removeFileIfContained(partialURL, in: destination)
        removeFileIfContained(finalURL, in: destination)
        pruneEmptyDirectories(for: [relativePath], in: destination)
    }

    /// Re-derives the item's byte/progress totals from its currently selected
    /// files, so deleting a file leaves the row consistent (e.g. a complete
    /// torrent stays complete over its remaining selection).
    private func recomputeTotals(itemIndex: Int) {
        let selected = items[itemIndex].files.filter(\.isSelected)
        let downloaded = selected.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        let total = selected.reduce(Int64(0)) { $0 + $1.totalBytes }
        items[itemIndex].downloadedBytes = downloaded
        items[itemIndex].totalBytes = total
        items[itemIndex].progress = total > 0 ? min(1, Double(downloaded) / Double(total)) : 0
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

    func removeFiles(for item: TorrentItem, after task: Task<Void, Never>?) async {
        await task?.value
        // Only delete paths we actually resolved. An unresolved/queued row has no
        // `outputRelativePaths`, and guessing from `item.name` risks deleting an
        // unrelated file that happens to share the display name.
        let relativePaths = item.outputRelativePaths
        guard !relativePaths.isEmpty else {
            logger.notice("Skipping disk deletion for unresolved row \"\(item.name, privacy: .public)\": no resolved output paths")
            return
        }
        let destination = item.destination.standardizedFileURL
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
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("Failed to delete \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
    private func update(_ id: TorrentItem.ID, mutate: (inout TorrentItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            mutate(&items[index])
        } else if let index = pendingItems.firstIndex(where: { $0.id == id }) {
            mutate(&pendingItems[index])
        }
    }

    // MARK: - Persistence

    /// Rebuilds the confirmed list from a saved snapshot. Each item's metainfo is
    /// reconstructed offline from its stored `info` dictionary; items whose
    /// metainfo can't be rebuilt are dropped rather than restored broken.
    private func restore(_ snapshot: PersistedSession) {
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
            logger.error("Dropping restored row \"\(persisted.name, privacy: .public)\": stored info dict failed to parse: \(error.localizedDescription, privacy: .public)")
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
    private func resumeRestoredDownloads() {
        for item in items where item.state == .downloading {
            guard let metainfo = metainfos[item.id] else { continue }
            update(item.id) { $0.status = "Resuming download." }
            launchDownloadTask(itemID: item.id, metainfo: metainfo)
        }
    }

    /// Serializes the current confirmed list to disk off the main actor. Only
    /// items with a known metainfo are saved (so they can be rebuilt on launch).
    private func persist() {
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

public enum DefaultDownloadDirectory {
    public static func url() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}
