import Foundation

extension TorrentSession {
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

    func removeFiles(for item: TorrentItem, after task: Task<Void, Never>?) async {
        await task?.value
        // Only delete paths we actually resolved. An unresolved/queued row has no
        // `outputRelativePaths`, and guessing from `item.name` risks deleting an
        // unrelated file that happens to share the display name.
        let relativePaths = item.outputRelativePaths
        guard !relativePaths.isEmpty else {
            logger.notice("Skipping disk deletion for unresolved row \"\(item.name, privacy: .private)\": no resolved output paths")
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
            logger.error("Failed to delete \(path, privacy: .private): \(error.localizedDescription, privacy: .private)")
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
}
