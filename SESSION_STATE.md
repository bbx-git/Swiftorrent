# Session State

_Overwritten at every wrap-up, never appended. Under 30 lines; git has the history. Don't record build or test status._

- **Active plan:** none

## What this is
Download-only BitTorrent client (macOS 26, SwiftUI, no deps). Modules: `Packages/Core` (SwiftorrentCore: bencode, trackers, DHT, peer wire, MSE, downloader), `Domain` (TorrentSession, store), `Features` (SwiftUI), app in `App/Swiftorrent`, bench in `Tools/SwiftorrentBench`.

## Recent fixes (don't regress)
- Add-window dismissal must not cancel the task `startDownload` just stored in `tasks[itemID]` (downloads never started).
- Magnet resolve overlaps peer discovery with metadata fetch (18 s -> ~1 s); don't serialize them again.
- `NWConnection` continuations are resume-once (`ResumeOnce`); a double resume crashed under cancellation.

## Next
1. Magnet path on the new layout: `swiftorrent-bench --magnet ... --resolve-only` on the Debian magnet (`docs/BENCHMARK.md`). The `.torrent` swarm path is validated (2026-10-14).
2. Magnet-path TTFB follow-ups listed in `docs/BENCHMARK.md`.
3. Add a test target to `Packages/Features`; record uTP and notarization (`Scripts/notarize.sh`) as future work.

## Open problems
- Inbound-only peers unreachable by design (`docs/decisions/0002-download-only-policy.md`).
