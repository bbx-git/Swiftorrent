# Swiftorrent

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.3%2B-orange)
![Xcode](https://img.shields.io/badge/Xcode-26.5%2B-blue)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

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
- Resolves magnet metadata through BEP 5 DHT `get_peers`, BEP 10 extension negotiation, and BEP 9 `ut_metadata` requests. Peer collection returns as soon as it has gathered enough peers or an 18s deadline elapses (rather than blocking on the slowest source, e.g. a DHT sweep), and metadata is fetched by a bounded pool of concurrent peer probes that keeps only the peers that actually connect and retries them until one delivers SHA-1-verified metadata or a 90s phase deadline elapses. A reachable peer that turns out not to hold the metadata (a leecher) is dropped in about one round-trip instead of parking a probe slot.
- Discovers `.torrent` download peers through HTTP/HTTPS trackers, UDP trackers, and BEP 5 DHT `get_peers`.
- Implements a peer-wire downloader for `.torrent` metadata: handshake, interested, bitfield/have availability tracking, a self-replenishing pool of concurrent peer downloads (up to 16 workers draw from a shared reserve seeded with up to 300 peers and replace any peer that dies or runs dry), rarest-first piece scheduling, unchoke handling, **pipelined block requests** (up to 16 × 16 KB blocks in flight per piece, re-requested after a choke, so throughput isn't capped at one block per round-trip), SHA-1 piece verification, existing-piece resume checks, and file writing. Peer discovery for the swarm starts as soon as ~100 peers are found (or a 12s deadline), rather than waiting for the slowest tracker/DHT, so the first byte arrives quickly. A supervisor keeps the reserve from ever permanently running dry: it re-announces to trackers/DHT on an interval and folds the fresh peers in (alongside inbound PEX), and the download fails only if the swarm makes no byte progress at all for several minutes — important for a download-only client, whose non-uploading peers are kept choked by tit-for-tat, so it must keep reaching actual seeds.
- Bounds every peer-wire network wait with connect and per-operation send/receive timeouts, so a peer that goes silent mid-message is torn down instead of parking a download slot.
- Discovers additional inbound peers through BEP 11 PEX: each peer-wire connection advertises `ut_pex` and folds the compact-IPv4 peer lists peers gossip back into whichever peer pool is active. Because PEX lives in the peer-wire layer it benefits three phases: `.torrent` swarm downloads and magnet swarm downloads (gossip goes into the swarm's replacement reserve, deduped against peers already queued), **and the magnet metadata exchange itself** (gossip goes back into the concurrent metadata-probe pool, so the info-hash → metadata phase reaches seeds beyond the initial tracker/DHT set). Download-only: the client consumes `added` lists only and never advertises itself as a source (`added6`/IPv6 entries are ignored, matching the IPv4 tracker/DHT paths).
- Presents an add dialog the moment you open a `.torrent` or paste a magnet: it shows a resolving spinner while metadata loads, then per-file checkboxes, Select All / Deselect All, and a running selected-size total, so you pick what to download before any data is fetched. Each add dialog is its own independent window, so opening several links in a row stacks a window per torrent instead of hiding later ones behind the first. The torrent only appears in the list after you click **Download**; closing a dialog window (Cancel, or the window's close button) cancels adding that torrent entirely (nothing is written to disk) without affecting any other add dialog still open.
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

- Downloads (both `.torrent` and resolved magnets) use a self-replenishing pool of concurrent tracker/DHT/PEX peers with basic piece availability tracking, support per-file selection (full and partial), and honor a global download-speed cap. The downloader does not yet use local peer discovery, NAT traversal, uTP, or endgame mode.
- **Outbound protocol encryption (MSE/PE, BEP-8 Message Stream Encryption).** Every peer connection first attempts the MSE handshake — Diffie-Hellman key exchange over MSE's fixed 768-bit group followed by an RC4-encrypted stream — and only falls back to a plaintext handshake if the peer isn't MSE-capable. This reaches the encryption-required majority of public-swarm peers that accept a TCP connection but stay silent on a plaintext handshake. Both `.torrent` and magnet swarm downloads use it (they share the peer-wire layer). The DH modular exponentiation and RC4 are implemented in pure Swift (`MSECrypto.swift`); SHA-1 comes from CryptoKit. Live-validated against the Big Buck Bunny swarm: of 13 peers that connected, 12 negotiated RC4 encryption and 11 downloaded and SHA-1-verified real pieces. Encryption changes only the transport — Swiftorrent stays strictly download-only, with no listening port and no upload.
- **Still no listening port.** We never accept inbound connections, so NAT'd peers that only accept inbound remain unreachable. With MSE now in place, the remaining reach gap is these inbound-only peers plus swarms with no reachable seed at all.
- Magnet links fetch metadata (BEP 9 `ut_metadata`) from peers discovered through HTTP/HTTPS trackers, UDP trackers, or DHT, and also from peers those peers gossip via BEP 11 PEX during the exchange (folded back into the metadata-probe pool); once metadata is resolved the swarm download uses the same tracker/DHT/PEX peer discovery as `.torrent` files. Live-validated end-to-end: a real multi-file magnet resolves in ~24s and Big Buck Bunny resolves from many peers with SHA-1-verified metadata pieces (the metadata-path PEX feed is covered by offline tests but not yet separately live-validated).
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

### Opening the app on another Mac

`package_app.sh` **ad-hoc signs** the bundle, which is enough to run on the machine
that built it but not to pass Gatekeeper on someone else's Mac. When you copy the
`.app` to another Mac it will be quarantined, so the first launch needs one of:

- **Right-click the app → Open**, then confirm in the dialog (only needed once), or
- strip the quarantine attribute from a terminal:

  ```sh
  xattr -dr com.apple.quarantine /path/to/Swiftorrent.app
  ```

This is normal for unsigned indie Mac apps — the app is fully functional, it just
isn't notarized. To make it launch with **no** prompt on any Mac, the bundle must
be signed with an Apple **Developer ID** certificate and notarized (requires a
paid Apple Developer account). That step can be added to the current
Swift Package build from the command line (`codesign` + `xcrun notarytool` +
`stapler`) — it does **not** require migrating to an Xcode project.

### Live download smoke test

`big-buck-bunny.torrent` in the repository root is a well-seeded public-domain
torrent kept for end-to-end download testing (real tracker/DHT/peer swarm).
Open it in the packaged app to verify the download path against a live swarm —
e.g. that the peer pool replenishes and the transfer completes and verifies
without seeding. (The unit tests cover parsing/layout/coordinator logic only.)

To exercise the magnet path (info-hash → metadata exchange → swarm), paste this
Big Buck Bunny magnet link into the **Magnet** field:

```text
magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.coppersurfer.tk%3A6969&tr=udp%3A%2F%2Ftracker.empire-js.us%3A1337&tr=udp%3A%2F%2Ftracker.leechers-paradise.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=wss%3A%2F%2Ftracker.btorrent.xyz&tr=wss%3A%2F%2Ftracker.fastcast.nz&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&ws=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2F&xs=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2Fbig-buck-bunny.torrent
```

### Download-speed benchmark

To measure Swiftorrent's download engine and compare it against **aria2c** and
**transmission-cli**, use the headless `swiftorrent-bench` harness (it drives the
real `SwiftorrentCore.TorrentDownloader` and builds **without full Xcode**):

```bash
brew install aria2 transmission-cli
swift build -c release --product swiftorrent-bench
Scripts/benchmark.sh big-buck-bunny.torrent bbb
```

See **[BENCHMARK.md](BENCHMARK.md)** for the full procedure, latest results,
conclusions, and the optimization TODO.

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

All items preserve the download-only policy (no seeding, uploading, or sharing). PEX is implemented inbound-only: the client consumes peer lists and never advertises itself as a source. Completed work is dropped from this list; see **Features** above and `SESSION_STATE.md` for what already ships. (Peer-pool replenishment, inbound BEP 11 PEX, and outbound MSE/PE encryption have shipped and are validated against a live swarm — see **Features**.)

### Priority: reach more peers

- BEP 11 PEX during the magnet *metadata* exchange, to discover more reachable peers while resolving (PEX already drives the swarm download for both `.torrent` and magnet downloads, and MSE now encrypts those connections; only the info-hash→metadata step is still trackers + DHT).

### Larger, optional

- Endgame mode (re-request the last in-flight pieces across peers so the tail doesn't stall).
- uTP transport for networks that throttle plain BitTorrent TCP.
- Migrate to a native Xcode app target to drop the manual `.app` bundling step.
