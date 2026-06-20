# SESSION_STATE.md

## Context Snapshot
- **Project:** Swiftorrent
- **Current Architecture:** Package-first modular Swift Package with Core, Domain, Features, and a thin SwiftUI app executable.
- **Swift Version:** 6.3.2
- **Next Immediate Step:** P2 verified-piece caching and web-seed HTTP `Range`/resume are done. Next P2: PEX (inbound-only), then per-wait peer-wire timeouts and file selection.

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
  - Added bounded concurrent peer downloads with bitfield/have availability tracking, rarest-first scheduling, and serialized piece writes.
  - Added tests for tracker percent encoding, compact IPv4 peer parsing, and peer bitfield parsing.
  - Added BEP 5 DHT `get_peers` discovery for magnet metadata resolution, including compact IPv4 node/peer parsing tests.
  - Added BEP 5 DHT peer discovery to `.torrent` downloads, merged with tracker peers before the existing concurrent piece scheduler runs.
  - Added torrent-list removal confirmation from right-click, row remove button, and Delete/Backspace command; users can remove only from Swiftorrent or also delete downloaded/partial files from disk.
  - Changed app accent styling from blue to graphite black/grey.
  - Fixed all P0 (critical) roadmap items: untrusted-input crash/OOM/hang hardening across bencode, peer-wire, tracker, and DHT paths.
- **Recent Fixes (Anti-Regression):**
  - P2: web-seed HTTP `Range`/resume. `TorrentFileWriter.partialFileResumeOffset(for:)` reports how many bytes of a file are already on disk (resumes from a `.tor` partial, truncates an oversized/corrupt partial to 0, or reports full length when a completed final file exists so the fetch is skipped). `downloadWebSeedFile` now sends `Range: bytes=offset-` and seeks to the offset on a `206`, rewrites from 0 on a `200` (server ignored the range), and fails over to the next seed/peers on any other status — so an interrupted web-seed download no longer restarts each file from byte 0. Added a resume-offset test covering fresh/partial/oversized/complete states.
  - P2: verified-piece caching. `download()` now does one full `verifiedPieces()` hash scan, carries the set forward in a `var`, and after web seeds refreshes only the still-unverified indices via the new `TorrentFileWriter.verifiedPieces(among:)`. The pre-peer-download path reuses the cached set (peer discovery does no disk I/O), eliminating the previous up-to-3× full re-hash per download. Also hardened `makePeerID()` to build 20 ASCII bytes from `utf8` (no force-unwrapped `data(using: .ascii)!`). Added tests: piece-subset verification and 20-byte ASCII peer id.
  - P1: empty-availability heuristic fixed. `PeerWireClient.currentAvailability()` exposes `(pieces, isKnown)`; the download loop now queries live availability each pass, so `have`/`bitfield` messages received mid-download refine the set. The optimistic "assume full seed" fallback now applies only while the peer is undeclared (unchoked first) and self-corrects once it announces anything. The frozen `PeerDownloadSession.availablePieces` snapshot is now only used to seed rarest-first counts.
  - P1: `TrackerClient.makeAnnounceURL` now returns `URL?` (no `URL(string:)!` force-unwrap), refactored to a testable `static` helper; `announce` throws `invalidTrackerURL` when the URL can't be built, so the failing tracker is skipped by the per-tracker `catch` in `TorrentDownloader`/`MagnetMetadataResolver` group tasks instead of crashing.
  - P1: `PeerWireClient.connect` handles `.waiting` (cancels + fails fast on unreachable/refused peers) and `.cancelled` (resumes with `CancellationError`, no continuation leak); same `.waiting` fail-fast added to `TrackerClient`/`DHTClient` `waitUntilReady`.

## Known Issues / Technical Debt
- Magnet and `.torrent` peer discovery can use HTTP/HTTPS trackers, UDP trackers, and DHT peer discovery, but PEX is still missing.
- Downloader uses a small concurrent peer pool with basic timeouts, but still needs broader integration testing against external assets.
- Disk deletion currently removes known torrent output paths and partial `.tor` files; unresolved queued rows fall back to a best-effort path based on the displayed item name.
- Manual app bundling is required because the current project is an SPM executable instead of a native Xcode app target.
- The user-provided magnet was used only for parser/hash/tracker-shape verification, not media download. Future external test assets must use `~/Documents/Xcode/aTemp`.

## Decisions & Rationale
- **Pure Swift/Apple-only:** Uses SwiftUI, Observation, Foundation, Network, CryptoKit, AppKit, and UniformTypeIdentifiers only.
- **Download-only:** No peer listener, tracker port is `0`, uploaded is always `0`, no block upload handling, and completion sends stopped announce.
- **Default downloads location:** Uses the system `.downloadsDirectory` URL so localized user folders work correctly.
- **Transmission reference:** Transmission was consulted for protocol concepts only; no code was copied or translated.

## Build & Run Status
- **Last Build:** Success, Release mode via `Scripts/package_app.sh`.
- **Tests:** Success, `swift test -c release`, 27 Swift Testing tests passed (latest add: web-seed resume offset across fresh/partial/oversized/complete states).
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
- All P0/P1 done; P2 verified-piece caching, the `makePeerID` force-unwrap, and web-seed `Range`/resume are done. Next up: P2 — PEX (inbound-only), per-wait peer-wire timeouts, file selection — plus the two remaining hardening tests (cancellation teardown timing; integration tests from `~/Documents/Xcode/aTemp`).
