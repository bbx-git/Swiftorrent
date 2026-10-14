# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** none

## What this is
Download-only BitTorrent client (macOS 26, SwiftUI, no deps). Modules: `Packages/Core` (SwiftorrentCore: bencode, trackers, DHT, peer wire, MSE, downloader), `Domain` (TorrentSession, store), `Features` (SwiftUI, has a test target), app in `App/Swiftorrent`, bench in `Tools/SwiftorrentBench`.

## Recent fixes (don't regress)
- Add-window dismissal must not cancel the task `startDownload` just stored in `tasks[itemID]` (downloads never started).
- Magnet resolve overlaps peer discovery with metadata fetch (18 s -> ~1 s); don't serialize them again.
- `NWConnection` continuations are resume-once (`ResumeOnce`); a double resume crashed under cancellation.
- DHT lookup is closest-first with a sliding window and bootstrap re-seed; don't revert to batch-and-wait (`docs/decisions/0005-dht-closest-first.md`).
- Web-seed segments are written strictly in order; resume depends on the partial file being a contiguous prefix (`docs/decisions/0004-web-seed-ordered-segments.md`).

## Next
1. Future work (in `docs/FEATURES.md`): uTP, notarization (`Scripts/notarize.sh`); both need the user's direction.
2. Optional: a longer trackerless sweep over other info-hashes (only Debian was measured).

## Open problems
- Inbound-only peers unreachable by design (`docs/decisions/0002-download-only-policy.md`).
