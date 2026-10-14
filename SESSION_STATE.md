# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** `docs/plans/hardening-2.md`, steps 1-5 done; step 6 (split `PeerWireClient`, `TorrentSession`, `SwiftorrentRootView`) left.

## What this is
Download-only BitTorrent client (macOS 26, SwiftUI, no deps). Modules: `Packages/Core` (SwiftorrentCore: bencode, trackers, DHT, peer wire over TCP/uTP, MSE, downloader), `Domain` (TorrentSession, store), `Features` (SwiftUI, has a test target), app in `App/Swiftorrent`, bench in `Tools/SwiftorrentBench`.

## Recent fixes (don't regress)
- No download traces (`docs/decisions/0008-no-download-traces.md`): all HTTP uses `URLSession.traceless` (never `.shared`; test `TracelessHTTPTests`); torrent names/paths log `.private`.
- Timeouts use `withDeadline` (dispatch timer), never a racing `Task.sleep`: cancelled sleeps lingered until their deadline, ~510k per download (test `DeadlineTests`).
- uTP buffers are `[UInt8]`; `Data.removeFirst` keeps consumed bytes (test `receiveBufferDoesNotKeepConsumedBytes`). Don't use `Data` for long-lived consume-from-front buffers.
- `PieceDownloadCoordinator.complete` returns a fresh per-file copy only when progress is due (TSan flagged the shared buffer).
- Add-window dismissal must not cancel the task `startDownload` stored in `tasks[itemID]`.
- Magnet resolve overlaps peer discovery with metadata fetch; `collectPeers` takes DHT peers streamed via `onPeers` (test `streamedDHTPeersDoNotWaitForTheWalk`).
- `NWConnection` continuations are resume-once (`ResumeOnce`); uTP `receive` fails promptly after close (test `receiveAfterCloseFailsPromptly`).
- DHT lookup closest-first (decision 0005); web-seed segments written in order (decision 0004); uTP outbound-only, TCP first (decision 0006).
- `stopped` announce capped at 3 s and sent on every non-complete exit; quit waits via `TorrentSession.stopAll()` (tests `stoppedAnnounceIsCapped`, `failedDownloadAnnouncesStopped`).
- Hostile-input limits (decision 0007; tests `HostileInputTests`, `BoundedHTTPTests`, `FuzzTests`). Custom speed limit via `SpeedLimitInput`.
- `remove(deleteFiles:)` deletes only after the cancelled task finishes (test `SessionRemoveFilesTests`).
- Dock badge is a fixed-size `DockBadge` tile with an app-lifetime observation loop; header glass controls need `.tint(.primary)`; icon from `Scripts/make-icon.swift`.

## Next
- Plan step 6 (file splits, no behaviour change).
- Sanitizer/soak/profile recipe is in `docs/BENCHMARK.md` (2026-10-14 section); re-run after engine changes.

## Open problems
- Inbound-only peers unreachable by design; tracker `port` is 0 (decision 0002).
- Under ASan, one magnet run took ~100 s to first byte after resolve (normal build 1.6-2.5 s); likely handshake timeouts from ASan slowdown, unverified.
