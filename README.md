# Swiftorrent

Swiftorrent is a simple macOS torrent client built in 100% Swift and SwiftUI. The app is designed as a download-only BitTorrent client: it does not listen for incoming peers, announces `uploaded=0`, never sends piece data to peers, and stops when a download completes instead of seeding.

## Features

- Modern SwiftUI macOS 26 interface with graphite Liquid Glass controls, a sidebar, torrent list, progress rows, and folder picker.
- Default download folder uses `FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)`, so it respects the user's localized system Downloads directory.
- Opens `.torrent` files from the UI and from app/document open URLs.
- Accepts `magnet:` URLs from the UI and from app URL opening.
- Parses bencoded torrent metainfo, computes SHA-1 info hashes from the raw `info` dictionary, reads single-file and multi-file torrents, and extracts tracker tiers.
- Talks to HTTP and HTTPS trackers with compact peer responses.
- Talks to UDP trackers with compact IPv4 peer responses.
- Resolves magnet metadata through BEP 5 DHT `get_peers`, BEP 10 extension negotiation, and BEP 9 `ut_metadata` requests.
- Discovers `.torrent` download peers through HTTP/HTTPS trackers, UDP trackers, and BEP 5 DHT `get_peers`.
- Implements a peer-wire downloader for `.torrent` metadata: handshake, interested, bitfield/have availability tracking, bounded concurrent peer downloads, rarest-first piece scheduling, unchoke handling, block requests, piece receipt, SHA-1 piece verification, existing-piece resume checks, and file writing.
- Performs a free-space check before writing torrent data.
- Cancels active tracker and peer work when a torrent row is removed, with a choice to remove only from Swiftorrent or also delete downloaded/partial files from disk.
- Sanitizes torrent file names and multi-file path components before writing into the chosen destination.
- Uses Swift Testing for core parser coverage.

## Current Limitations

- `.torrent` downloads now use a small pool of concurrent tracker/DHT peers with basic piece availability tracking. The downloader does not yet use PEX, local peer discovery, encryption, NAT traversal, bandwidth limits, or partial file selection.
- Magnet links can now fetch metadata from peers discovered through HTTP/HTTPS trackers, UDP trackers, or DHT. PEX is still missing.
- The app is packaged from the Swift Package executable into a drag-and-drop `Swiftorrent.app`; there is no `.xcodeproj` app target yet.

## Requirements

- macOS Tahoe 26.0 or newer.
- Xcode 26.5 or newer.
- Swift 6.3.2 or newer.
- Apple frameworks only: SwiftUI, Observation, Foundation, Network, CryptoKit, AppKit, and UniformTypeIdentifiers.
- No third-party dependencies.

## Build, Test, and Deploy

Build Release with local DerivedData/output:

```sh
xcodebuild -scheme Swiftorrent -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build/DerivedData SYMROOT=.build/output
```

Run tests:

```sh
swift test -c release
```

Package the drag-and-drop app bundle:

```sh
Scripts/package_app.sh
```

The packaged app is written to `.build/output/Release/Swiftorrent.app` and copied to `~/Applications/Swiftorrent.app`.

## Usage

1. Launch `Swiftorrent.app` from `~/Applications` or `.build/output/Release`.
2. Use **Open .torrent** to choose a torrent file, or paste a magnet link into the Magnet field.
3. The default destination is the user's localized Downloads folder.
4. Use **Choose Folder** to select a different destination before adding a torrent.
5. Completed downloads stop without seeding.

## Architecture

```text
Swiftorrent/
├── Package.swift
├── App/
│   ├── Resources/Info.plist
│   └── Sources/SwiftorrentApp/
├── Packages/
│   ├── SwiftorrentCore/
│   │   ├── Sources/SwiftorrentCore/
│   │   │   ├── Bencode.swift
│   │   │   ├── DHTClient.swift
│   │   │   ├── MagnetLink.swift
│   │   │   ├── MagnetMetadataResolver.swift
│   │   │   ├── PeerWireClient.swift
│   │   │   ├── TorrentDownloader.swift
│   │   │   ├── TorrentMetainfo.swift
│   │   │   └── TrackerClient.swift
│   │   └── Tests/SwiftorrentCoreTests/
│   ├── SwiftorrentDomain/
│   │   └── Sources/SwiftorrentDomain/TorrentSession.swift
│   └── SwiftorrentFeatures/
│       └── Sources/SwiftorrentFeatures/SwiftorrentRootView.swift
├── CLAUDE.md
├── README.md
└── SESSION_STATE.md
```

The root manifest is an umbrella manifest for reliable `xcodebuild` schemes. The local package manifests remain under `Packages/` so each layer can still be developed independently.

## Protocol Notes

- Upload avoidance is enforced by policy: no listener socket, tracker `port=0`, tracker `uploaded=0`, no piece upload message handling, no seeding loop, and a best-effort stopped announce after completion.
- UDP tracker support uses BEP 15 connect/announce requests and compact IPv4 peers.
- DHT support uses BEP 5 `get_peers` queries against public bootstrap nodes and consumes compact IPv4 peers/nodes for magnet metadata and `.torrent` downloads.
- Magnet metadata resolution uses the extension-protocol reserved bit, extended handshake message ID `20`, and `ut_metadata` request/data messages.
- Transmission was used only as protocol/architecture reference. No Transmission source code was copied or translated.

## Roadmap

All items preserve the download-only policy (no seeding, uploading, or sharing). PEX, if added, is inbound-only: consume peer lists, never advertise this client as a source.

### P0 — Critical (crash / OOM / hang from untrusted input)

- Make connections cancellation-aware. `withTimeout` cannot interrupt the bare `withCheckedThrowingContinuation` wrappers over `NWConnection` (`PeerWireClient.receiveExactly`, `TrackerClient.receiveUDP`, `DHTClient.receive`), so a non-responsive or hostile host deadlocks the timeout and blocks user cancellation. Wrap each connection await in `withTaskCancellationHandler` whose `onCancel` calls `connection.cancel()`.
- Bound peer-supplied lengths to prevent OOM. Cap `PeerWireClient.readMessage`'s 4-byte length prefix (e.g. ≤ 1 MB) before `receiveExactly`, and cap the peer-advertised `metadata_size`/derived `pieceCount` in `fetchMetadata` (e.g. ≤ 10 MB).
- Guard the bencode byte-string length against integer overflow (`Bencode.swift`: `length = length*10 + …` can trap on a crafted `.torrent`). Use overflow-reporting arithmetic or cap to remaining bytes.
- Filter `port == 0` in `TrackerClient.parseCompactPeers` (the dict and DHT parsers already do) and stop force-unwrapping `NWEndpoint.Port(rawValue:)` in `PeerWireClient.connect`, which currently crashes on a port-0 peer.

### P1 — Important (robustness / correctness)

- Fix the `connect()` continuation leak: handle `.waiting` and `.cancelled` `NWConnection` states, not just `.ready`/`.failed`.
- Replace fire-and-forget `Task { await client.close() }` cleanup in `TorrentDownloader` and `MagnetMetadataResolver` with an awaited/structured close.
- Stop force-unwrapping `URL(string:)!` in `TrackerClient.makeAnnounceURL`; return optional and skip the tracker on failure.
- Address the empty-availability heuristic (a peer that unchokes before sending bitfield/have is treated as a full seed); add reject/`have` handling or document it.

### P2 — Performance & polish

- Cache verified pieces; `verifiedPieces()` re-hashes the whole on-disk dataset and runs up to 3× per `download()`.
- Add HTTP `Range`/resume support to web-seed downloads (currently GETs whole files; mid-file failure restarts the file).
- Reduce fragile force-unwraps in `makePeerID` and the `SecRandomCopyBytes` path.
- Add PEX (inbound peer discovery only).
- Add peer-wire read/connect timeouts for every long-running network wait.
- Add file selection and per-file progress.

### Hardening tests to add

- Bencode length overflow rejected on a crafted `.torrent`.
- `parseCompactPeers` drops port-0 entries.
- Oversized `metadata_size` / wire-message length rejected.
- Cancellation tears down a stalled connection within the timeout window.
- Integration tests using assets only from `~/Documents/Xcode/aTemp`.
