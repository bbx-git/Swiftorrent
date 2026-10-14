# Swiftorrent

A download-only BitTorrent client for macOS, built in pure Swift and SwiftUI with no third-party dependencies.

## Features
- Open `.torrent` files or paste `magnet:` links; pick files in an add dialog before anything downloads
- HTTP/UDP trackers, DHT, PEX, web seeds, MSE/PE encryption, and uTP for peers TCP can't reach
- Pause/resume, global speed cap, per-file progress, list restored across launches
- Never seeds or uploads: no listening port, stops when a download completes

Full list and protocol notes: [docs/FEATURES.md](docs/FEATURES.md).

## Requirements
- macOS 26.0 or newer
- Latest stable Swift toolchain (Swift 6.3+; Xcode or Command Line Tools)

## Build and run
```sh
Scripts/build.sh
```
Builds the Release binary with SwiftPM, wraps it in a `.app`, signs it ad hoc and installs it to `~/Applications/`. The app name comes from `App/Resources/Info.plist`, so the script needs no edits per app. The log is in `tmp/build.log`. Unit tests: `swift test -c release -Xswiftc -enable-testing --package-path Packages/Core` (and `Packages/Domain`, `Packages/Features`).

## More
- Project layout and module rules: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Current status and next steps: [SESSION_STATE.md](SESSION_STATE.md)
- How to work with Claude Code here: [docs/WORKFLOW.md](docs/WORKFLOW.md)
- Unsigned-app workaround and live smoke test (Big Buck Bunny torrent and magnet): [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)
- Download-speed benchmark: [docs/BENCHMARK.md](docs/BENCHMARK.md)
