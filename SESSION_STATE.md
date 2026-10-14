# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** `docs/plans/hardening-2.md`, steps 1-5 done; step 6 (split `PeerWireClient`, `TorrentSession`, `SwiftorrentRootView`) left.

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
- Dock badge is a fixed-size `DockBadge` tile; header glass controls need `.tint(.primary)`.

## Next
- Plan step 6 (file splits, no behaviour change).
- Maybe: `Scripts/build.sh` should quit a running copy before installing (a stale running app made a fix look broken).
- Bench: `--utp-probe` prints TCP connect percentiles; download runs print each status change with its time.

## Open problems
- Inbound-only peers unreachable by design; tracker `port` is 0 (decision 0002).
- Suspected, unmeasured: choked peers that keep sending HAVEs are never dropped (90 s idle timer resets), so in a thin swarm they could hold all 100 slots.
