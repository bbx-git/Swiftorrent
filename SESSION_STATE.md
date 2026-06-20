# SESSION_STATE.md

## Context Snapshot
- **Project:** Swiftorrent
- **Current Architecture:** Package-first modular Swift Package with Core, Domain, Features, and a thin SwiftUI app executable.
- **Swift Version:** 6.3.2
- **Next Immediate Step:** Add UDP tracker support so magnets with mostly UDP trackers can resolve peers more reliably.

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
  - Added HTTP/HTTPS tracker announce support with `uploaded=0`, compact peer parsing, and no listener port.
  - Added first-pass peer-wire download path for `.torrent` files.
  - Added BEP 10/BEP 9 magnet metadata resolution for peers discovered through HTTP/HTTPS trackers.
  - Added manual `.app` bundling metadata for `.torrent` and `magnet:` open support.
- **In Progress:**
  - UDP tracker support is not implemented yet, so UDP-only magnets cannot resolve peers.
- **Recent Fixes (Anti-Regression):**
  - Added magnet metadata resolver and connected magnet rows to the normal download path after metadata is fetched.
  - Added bencode encoder and prefix parser for extension protocol messages.
  - Fixed Xcode nested local-package module resolution by making the root manifest an umbrella target graph.

## Known Issues / Technical Debt
- Magnet resolution currently depends on HTTP/HTTPS trackers returning peers; UDP trackers, DHT, and PEX are still missing.
- Downloader uses a minimal single-peer path and needs robust peer rotation, retries, piece availability tracking, resume data, UDP tracker support, and existing-piece verification.
- Manual app bundling is required because the current project is an SPM executable instead of a native Xcode app target.
- The user-provided magnet was used only for parser/hash/tracker-shape verification, not media download. Future external test assets must use `~/Documents/Xcode/aTemp`.

## Decisions & Rationale
- **Pure Swift/Apple-only:** Uses SwiftUI, Observation, Foundation, Network, CryptoKit, AppKit, and UniformTypeIdentifiers only.
- **Download-only:** No peer listener, tracker port is `0`, uploaded is always `0`, no block upload handling, and completion sends stopped announce.
- **Default downloads location:** Uses the system `.downloadsDirectory` URL so localized user folders work correctly.
- **Transmission reference:** Transmission was consulted for protocol concepts only; no code was copied or translated.

## Build & Run Status
- **Last Build:** Success, clean Release mode after deleting stale local DerivedData/output app artifacts, via `xcodebuild -scheme Swiftorrent -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build/DerivedData SYMROOT=.build/output DSTROOT=.build/install`
- **Tests:** Success, `swift test -c release`, 4 Swift Testing tests passed.
- **Deployment:** Fresh `Swiftorrent.app` created from `.build/output/Release/Swiftorrent`, ad hoc signed, verified, launched, quit, and copied to `~/Applications/Swiftorrent.app`.
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
- Start with UDP tracker support in `TrackerClient`, then add peer retry/rotation so both magnet metadata and piece downloads avoid depending on a single peer.
