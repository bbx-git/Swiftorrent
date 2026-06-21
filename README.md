# Swiftorrent

Swiftorrent is a simple macOS torrent client built in 100% Swift and SwiftUI. The app is designed as a download-only BitTorrent client: it does not listen for incoming peers, announces `uploaded=0`, never sends piece data to peers, and stops when a download completes instead of seeding.

## Features

- Modern SwiftUI macOS 26 interface with graphite Liquid Glass controls, a sidebar, torrent list, progress rows, and folder picker.
- Translucent Liquid Glass window: the title bar is hidden and the window is non-opaque with behind-window materials, so the app shows the blurred desktop and tracks the system Liquid Glass opacity slider / Reduce Transparency setting.
- Default download folder uses `FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)`, so it respects the user's localized system Downloads directory.
- Opens `.torrent` files from the UI and from app/document open URLs.
- Accepts `magnet:` URLs from the UI and from app URL opening.
- Parses bencoded torrent metainfo, computes SHA-1 info hashes from the raw `info` dictionary, reads single-file and multi-file torrents, and extracts tracker tiers.
- Talks to HTTP and HTTPS trackers with compact peer responses.
- Talks to UDP trackers with compact IPv4 peer responses.
- Resolves magnet metadata through BEP 5 DHT `get_peers`, BEP 10 extension negotiation, and BEP 9 `ut_metadata` requests.
- Discovers `.torrent` download peers through HTTP/HTTPS trackers, UDP trackers, and BEP 5 DHT `get_peers`.
- Implements a peer-wire downloader for `.torrent` metadata: handshake, interested, bitfield/have availability tracking, a self-replenishing pool of concurrent peer downloads (workers draw from a shared peer reserve and replace any peer that dies or runs dry, so the swarm refills toward full instead of bleeding out), rarest-first piece scheduling, unchoke handling, block requests, piece receipt, SHA-1 piece verification, existing-piece resume checks, and file writing.
- Bounds every peer-wire network wait with connect and per-operation send/receive timeouts, so a peer that goes silent mid-message is torn down instead of parking a download slot.
- Discovers additional inbound peers through BEP 11 PEX (consumes peer lists only; never advertises this client as a source).
- Presents an add dialog the moment you open a `.torrent` or paste a magnet: it shows a resolving spinner while metadata loads, then per-file checkboxes, Select All / Deselect All, and a running selected-size total, so you pick what to download before any data is fetched. The torrent only appears in the list after you click **Download**; dismissing the dialog cancels adding it entirely (nothing is written to disk).
- Offers a per-torrent "Create a subfolder named ..." option in that dialog so multi-file torrents can write their files directly into the destination instead of an enclosing folder. This affects only the on-disk output path; the torrent-relative paths used for web-seed URLs and the piece map are unchanged.
- Lets you choose which files in a multi-file torrent to download from the add dialog, downloading only the pieces overlapping the selected files (shared boundary pieces are fetched whole so selected edges still verify) and finalizing only the selected files. Partial selections download via web seeds when available (selected files are streamed whole and the deselected-neighbor slice of each shared boundary piece is range-fetched so it verifies) as well as via peers.
- Shows per-file download progress in an expandable file list for multi-file torrents, with a per-file trash button (and a confirmation warning) that permanently deletes that file from the drive and drops it from the torrent's selection.
- Displays a live combined download-speed statistic (bytes/s across all torrents) alongside active/done counts in the header.
- Caps total download throughput with a header speed-limit control: pick a preset (Unlimited or 128 KB/s–10 MB/s) or type an exact value in KB/s or MB/s via the "Custom…" field. The limit is a shared token bucket applied across all active web-seed and peer transfers (the combined rate stays at the cap even with several concurrent peer connections) and is remembered between launches.
- Remembers the torrent list across launches: the confirmed torrents, their file selection, destination, and progress are saved to `~/Library/Application Support/Swiftorrent/session.json` (each torrent's `info` dictionary is stored so the metainfo is rebuilt offline, no re-resolution). On the next launch the list is restored and any torrent that was actively downloading auto-resumes (re-verifying on-disk pieces); paused/complete/failed rows keep their state.
- Lets you pause and resume any active torrent from an SF Symbol button on its row; pausing keeps on-disk progress and resuming re-verifies existing pieces before continuing.
- Performs a free-space check before writing torrent data.
- Cancels active tracker and peer work when a torrent row is removed, with a choice to remove only from Swiftorrent or also delete downloaded/partial files from disk.
- Sanitizes torrent file names and multi-file path components before writing into the chosen destination.
- Uses Swift Testing for core parser coverage.

## Current Limitations

- `.torrent` downloads use a self-replenishing pool of concurrent tracker/DHT/PEX peers with basic piece availability tracking, support per-file selection (full and partial), and honor a global download-speed cap. The downloader does not yet use local peer discovery, encryption, NAT traversal, uTP, or endgame mode.
- Magnet links can fetch metadata from peers discovered through HTTP/HTTPS trackers, UDP trackers, or DHT.
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

### Live download smoke test

`big-buck-bunny.torrent` in the repository root is a well-seeded public-domain
torrent kept for end-to-end download testing (real tracker/DHT/peer swarm).
Open it in the packaged app to verify the download path against a live swarm —
e.g. that the peer pool replenishes and the transfer completes and verifies
without seeding. (The unit tests cover parsing/layout/coordinator logic only;
the astronomy media in `~/Documents/Xcode/aTemp` are not torrents.)

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

All items preserve the download-only policy (no seeding, uploading, or sharing). PEX, if added, is inbound-only: consume peer lists, never advertise this client as a source. Completed work is dropped from this list; see **Features** above and `SESSION_STATE.md` for what already ships. (Peer-pool replenishment shipped and is validated against a live swarm — see **Features**.)

### Robustness & polish (next)

- Harden best-effort file deletion for unresolved/queued rows (skip disk deletion when no resolved output paths exist instead of guessing the display name).
- Add structured logging (`os.Logger`) so currently-swallowed persistence and file-deletion failures are observable.
- Minor cleanups: drop a redundant rethrow in the web-seed writer; replace an avoidable force-unwrap in the peer handshake.

### Larger, optional

- Endgame mode (re-request the last in-flight pieces across peers so the tail doesn't stall).
- BEP 11 PEX on the magnet metadata path (already present on the `.torrent` path).
- uTP transport and/or MSE/PE stream encryption for networks that throttle plain BitTorrent TCP.
- Migrate to a native Xcode app target to drop the manual `.app` bundling step.
