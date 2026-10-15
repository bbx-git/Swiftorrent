# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** none.

## What this is
Download-only BitTorrent client (macOS 26, SwiftUI, no deps). Modules: `Packages/Core` (SwiftorrentCore: bencode, trackers, DHT, peer wire over TCP/uTP, MSE, downloader), `Domain` (TorrentSession, store), `Features` (SwiftUI, has a test target), app in `App/Swiftorrent`, bench in `Tools/SwiftorrentBench`.

## Recent fixes (don't regress)
- Adding with many torrents (decision 0010): `ConnectionBudget` shared across torrents, separate pool for resolve probes, magnet resolve never times out (status shows retries; tests `ConnectionBudgetTests`, `PatientResolveTests`). Speed from `liveBytes` (`SpeedWindow`, `ProgressThrottleTests`); the bar is verified-only.
- Finder-launched app has a 256-fd soft limit: 100 peers x TCP+uTP plus a second magnet resolve hit "Too many open files" and showed "The network operation timed out." `FileDescriptorLimit.raise()` runs at app start (test `FileDescriptorLimitTests`). The terminal bench has 1M, so it never reproduced.
- Choked peers give way: dropped after 60 s choked when untried peers wait, even if they keep sending HAVEs (decision 0009, `ChokedPeerTimeoutTests`). Progress carries connected/unchoked counts; the bench prints them.
- Slow start: uTP races TCP after a 1 s head start (`openFirst`, test `TransportRaceTests`, decision 0006); magnet resolver probes 64 peers at once; a web seed with no first chunk in 5 s is skipped, 10 s total before the swarm (tests in `WebSeedSegmentTests`). Numbers in `docs/BENCHMARK.md`, "Magnet slow start".
- No download traces (decision 0008): all HTTP uses `URLSession.traceless` (test `TracelessHTTPTests`); torrent names/paths log `.private`.
- Timeouts use `withDeadline`/`withDisarmableDeadline` (dispatch timer), never a racing `Task.sleep` per read (test `DeadlineTests`).
- uTP buffers are `[UInt8]`, not `Data` (test `receiveBufferDoesNotKeepConsumedBytes`).
- `PieceDownloadCoordinator.complete` returns a fresh per-file copy only when progress is due (TSan).
- Add-window dismissal must not cancel the task `startDownload` stored in `tasks[itemID]`.
- `NWConnection` continuations are resume-once (`ResumeOnce`); uTP `receive` fails promptly after close.
- DHT lookup closest-first (0005); web-seed segments written in order (0004); `stopped` announce capped at 3 s on every non-complete exit.
- Hostile-input limits (0007; `HostileInputTests`, `BoundedHTTPTests`, `FuzzTests`). `remove(deleteFiles:)` deletes only after the task finishes.
- `Scripts/build.sh` quits a running copy before installing (a stale running app made a fix look broken).
- Dock badge is a fixed-size `DockBadge` tile; header glass controls need `.tint(.primary)`.

## Next
- Nothing queued. If a thin swarm with real peers turns up, measure unchoked share before/after (0009) and note it in `docs/BENCHMARK.md`.

## Open problems
- Root package has no test target; `swift test --package-path .` exits 1 with "no tests found" (expected).
