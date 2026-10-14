# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** `docs/plans/choked-peer-slots.md`, not started. It still needs the user's OK, including using Internet Archive torrents in `Fixtures/` as thin swarms (no copyrighted torrents).

## What this is
Download-only BitTorrent client (macOS 26, SwiftUI, no deps). Modules: `Packages/Core` (SwiftorrentCore: bencode, trackers, DHT, peer wire over TCP/uTP, MSE, downloader), `Domain` (TorrentSession, store), `Features` (SwiftUI, has a test target), app in `App/Swiftorrent`, bench in `Tools/SwiftorrentBench`.

## Recent fixes (don't regress)
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
- Get the user's OK on the plan, then step 1: report the unchoked-peer count in `TorrentDownloadProgress` and print it in the bench.

## Open problems
- Inbound-only peers unreachable by design; tracker `port` is 0 (decision 0002).
- Confirmed in code, impact not measured: the 90 s idle timeout is a per-read timeout (`PeerWireClient+Download.swift:163`), so a choked peer that keeps sending HAVEs or keep-alives never loses its slot. The active plan measures this first.
- Root package has no test target; `swift test --package-path .` exits 1 with "no tests found" (expected).
