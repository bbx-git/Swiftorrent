# SESSION_STATE.md

## Context Snapshot
- **Project:** Swiftorrent
- **Current Architecture:** Package-first modular Swift Package with Core, Domain, Features, and a thin SwiftUI app executable.
- **Swift Version:** 6.3.2
- **Next Immediate Step:** Add multiple peer connections and piece availability tracking.

## Modules & Targets
- **App:** `SwiftorrentApp` in `App/Sources/SwiftorrentApp`
- **Core:** `SwiftorrentCore` for bencode, metainfo, magnet parsing, magnet metadata resolution, trackers, peer-wire, downloader, file writer.
- **Domain:** `SwiftorrentDomain` for `@Observable` torrent session state and default Downloads folder behavior.
- **Features:** `SwiftorrentFeatures` for SwiftUI root UI.
- **Tests:** `SwiftorrentCoreTests` using Swift Testing.

## Work Status
- **Done:**
  - Added umbrella `Package.swift` and local package manifests.
  - Added modern SwiftUI macOS UI for opening `.torrent`, pasting magnet links, choosing a destination, and showing progress.
  - Added `.torrent` metainfo parsing with raw `info` SHA-1 hashing.
  - Added magnet parser for SHA-1 BTIH hex/Base32 links.
  - Added HTTP/HTTPS and UDP tracker announce support with `uploaded=0`, compact peer parsing, and no listener port.
  - Added first-pass peer-wire download path for `.torrent` files.
  - Added BEP 10/BEP 9 magnet metadata resolution for peers discovered through HTTP/HTTPS or UDP trackers.
  - Added manual `.app` bundling metadata for `.torrent` and `magnet:` open support.
  - Added per-row task cancellation so removing a torrent stops active tracker/peer work.
  - Added torrent output path sanitization and parser tests for unsafe paths.
  - Added resume support by verifying existing destination pieces before downloading, skipping valid pieces, and overwriting missing/corrupt pieces.
- **Recent Fixes (Anti-Regression):**
  - Removing a torrent row now cancels the item task and cooperative cancellation checks stop tracker, magnet, and peer loops.
  - Torrent metainfo parsing now sanitizes single-file names and multi-file path components before writing.
  - Fixed piece hash extraction to use `Data` slice indices safely.
  - Fixed multi-file piece writing so `Data` slice indices remain valid when a piece crosses file boundaries.

## Known Issues / Technical Debt
- Magnet resolution can use HTTP/HTTPS and UDP tracker peers, but DHT and PEX are still missing.
- Downloader retries peers with basic timeouts, but still needs multiple concurrent peers and piece availability tracking.
- Manual app bundling is required because the current project is an SPM executable instead of a native Xcode app target.
- The user-provided magnet was used only for parser/hash/tracker-shape verification, not media download. Future external test assets must use `~/Documents/Xcode/aTemp`.

## Decisions & Rationale
- **Pure Swift/Apple-only:** Uses SwiftUI, Observation, Foundation, Network, CryptoKit, AppKit, and UniformTypeIdentifiers only.
- **Download-only:** No peer listener, tracker port is `0`, uploaded is always `0`, no block upload handling, and completion sends stopped announce.
- **Default downloads location:** Uses the system `.downloadsDirectory` URL so localized user folders work correctly.
- **Transmission reference:** Transmission was consulted for protocol concepts only; no code was copied or translated.

## Build & Run Status
- **Last Build:** Success, Release mode via `Scripts/package_app.sh`.
- **Tests:** Success, `swift test -c release`, 9 Swift Testing tests passed.
- **Deployment:** Fresh `Swiftorrent.app` should always be created from `.build/output/Release/Swiftorrent`, ad hoc signed, verified, launched if needed, quit, and copied to `~/Applications/Swiftorrent.app`. Do not copy builds to `/Applications`.
- **Test Assets:** No external test assets used; standard directory remains `~/Documents/Xcode/aTemp`.

## Recently Changed Files
- `Package.swift`
- `App/Resources/Info.plist`
- `App/Sources/SwiftorrentApp/SwiftorrentApp.swift`
- `Packages/SwiftorrentCore/Sources/SwiftorrentCore/*.swift`
- `Packages/SwiftorrentDomain/Sources/SwiftorrentDomain/TorrentSession.swift`
- `Packages/SwiftorrentFeatures/Sources/SwiftorrentFeatures/SwiftorrentRootView.swift`
- `Packages/SwiftorrentCore/Tests/SwiftorrentCoreTests/CoreParsingTests.swift`
- `README.md`
- `SESSION_STATE.md`

## Handoff for Next Context
- Start with multiple peer connections and piece availability tracking, then add tracker URL encoding and compact peer parsing tests.
