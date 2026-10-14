# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** `docs/plans/clear-completed.md` (not started; awaiting user's go and the "all complete" rule)

## What this is
Download-only BitTorrent client (macOS 26, SwiftUI, no deps). Modules: `Packages/Core` (SwiftorrentCore: bencode, trackers, DHT, peer wire over TCP/uTP, MSE, downloader), `Domain` (TorrentSession, store), `Features` (SwiftUI, has a test target), app in `App/Swiftorrent`, bench in `Tools/SwiftorrentBench`.

## Recent fixes (don't regress)
- Add-window dismissal must not cancel the task `startDownload` just stored in `tasks[itemID]` (downloads never started).
- Magnet resolve overlaps peer discovery with metadata fetch (18 s -> ~1 s); don't serialize them again.
- `NWConnection` continuations are resume-once (`ResumeOnce`); a double resume crashed under cancellation.
- DHT lookup is closest-first with a sliding window and bootstrap re-seed; don't revert to batch-and-wait (`docs/decisions/0005-dht-closest-first.md`).
- Web-seed segments are written strictly in order; resume depends on the partial file being a contiguous prefix (`docs/decisions/0004-web-seed-ordered-segments.md`).
- uTP is outbound-only, TCP first. `UTPPeerTransport.receive` must fail when the transport was closed before the waiter registered (parked a worker for a full timeout); regression test `receiveAfterCloseFailsPromptly` (`docs/decisions/0006-utp-outbound-fallback.md`).
- The final `stopped` announce is capped at 3 s (`announceStopped`); it must not wait for the full discovery deadline again (test `stoppedAnnounceIsCapped`).
- Dock badge shows combined speed via `DockBadge` (nil at 0); it's driven by the main window, so it goes stale if that window is closed mid-download.

## Next
1. Optional: if a 10+ s tail with uTP pieces recurs, deprioritise uTP peers in piece assignment.
2. Optional: a longer trackerless sweep over other info-hashes (only Debian was measured).

## Open problems
- Inbound-only peers unreachable by design (`docs/decisions/0002-download-only-policy.md`).
