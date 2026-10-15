import Foundation

extension TorrentSession {
    /// Combined download speed formatted for display, e.g. "1.2 MB/s".
    public var downloadSpeedDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadSpeed, countStyle: .file) + "/s"
    }

    /// Samples every downloading torrent's rate once a second from its live byte
    /// count (verified plus blocks of pieces still assembling, so the readout moves
    /// before the first piece verifies). The combined figure is the sum of the
    /// per-torrent rates, so pausing or removing one torrent never dents the others.
    func startSpeedSampler() {
        speedSampler = Task { [weak self] in
            let clock = ContinuousClock()
            var windows: [TorrentItem.ID: SpeedWindow] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = clock.now
                var total: Int64 = 0
                var live = Set<TorrentItem.ID>()
                for index in self.items.indices {
                    guard self.items[index].state == .downloading else {
                        if self.items[index].downloadSpeed != 0 { self.items[index].downloadSpeed = 0 }
                        continue
                    }
                    let id = self.items[index].id
                    live.insert(id)
                    let bytes = max(self.items[index].liveBytes, self.items[index].downloadedBytes)
                    let speed = windows[id, default: SpeedWindow()].add(bytes: bytes, at: now)
                    self.items[index].downloadSpeed = speed
                    total += speed
                }
                // Forget windows for rows that vanished or stopped downloading.
                windows = windows.filter { live.contains($0.key) }
                self.downloadSpeed = total
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
}
