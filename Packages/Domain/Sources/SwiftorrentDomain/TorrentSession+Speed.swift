import Foundation

extension TorrentSession {
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
    func startSpeedSampler() {
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
}
