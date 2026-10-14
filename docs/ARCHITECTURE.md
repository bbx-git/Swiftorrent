# Architecture

## Layout
```text
.
├── Package.swift           root package: the executable target <App> (path App/<App>)
├── App/
│   ├── Resources/Info.plist  bundle metadata; CFBundleExecutable = <App>
│   └── <App>/              @main, dependency wiring
│       └── Incubator/      experimental code (see below)
├── Packages/
│   ├── Core/               low-level building blocks: utilities, storage, networking
│   ├── Domain/             models and business logic
│   └── Features/           SwiftUI feature modules + DesignSystem
├── Tools/
│   └── SwiftorrentBench/   headless benchmark executable (Core only), product `swiftorrent-bench`
├── Fixtures/               big-buck-bunny.torrent (local/ is gitignored)
├── Scripts/                build.sh: app-agnostic Release build, .app packaging, install
│                           benchmark.sh: compares swiftorrent-bench with aria2c/transmission-cli
├── docs/
│   ├── ARCHITECTURE.md
│   ├── BENCHMARK.md        benchmark procedure, results, optimization TODO
│   ├── WORKFLOW.md         the user's guide (Claude skips it)
│   ├── decisions/          NNNN-short-title.md
│   └── plans/              active plans only
├── tmp/                    scratch and logs (gitignored)
├── CLAUDE.md
├── README.md
└── SESSION_STATE.md
```

## Dependency rules
- Imports only point down: App → Features → Domain → Core. Skipping a layer downward is fine; importing upward never is.
- Feature targets never import each other. Shared views go in the `DesignSystem` target; shared logic moves down to Domain.
- Domain and Core don't import SwiftUI, AppKit or UIKit.
- No source file belongs to more than one target. Code needed by two targets lives in a package.

## Thin targets
The app target only starts the app and wires dependencies. Everything else comes from packages.

## Incubator
New experimental features or tiny helpers may start in `App/<App>/Incubator/`. Move them into a package as soon as they stabilize or another target needs them.

## Packages
- Each package has `Package.swift`, `Sources/<Target>/` and `Tests/<Target>Tests/`. Every target gets a test target.
- `swift-tools-version`: latest. Platforms: the minimums in `README.md`.
- Feature targets use `swiftSettings: [.defaultIsolation(MainActor.self)]`. Core and Domain stay nonisolated, with explicit `Sendable` types.
- Tests load media from `Fixtures/` at the repo root (resolved from `#filePath`).

## Swiftorrent specifics
- Package directories are `Core`, `Domain`, `Features`; their modules keep the `Swiftorrent` prefix (`SwiftorrentCore`, `SwiftorrentDomain`, `SwiftorrentFeatures`) to avoid generic module names.
- The root `Package.swift` depends on the three packages by path. The executable target `Swiftorrent` (`App/Swiftorrent`) must match `CFBundleExecutable`.
- Run each package's tests with `--package-path Packages/<Name>`.
- `Tools/SwiftorrentBench` is a second root executable target that depends only on Core. It is not part of the app bundle.
- Download-only policy: [decisions/0002-download-only-policy.md](decisions/0002-download-only-policy.md).
- Peer transport: `PeerWireClient` talks to a `PeerTransport` (`TCPPeerTransport`, `UTPPeerTransport` in `PeerTransport.swift`). uTP is a sans-I/O state machine (`UTPConnectionCore`, driven by tests with a virtual clock) plus the `UTPPacket` codec; `UTPProbe` backs `--utp-probe`. See [decisions/0006-utp-outbound-fallback.md](decisions/0006-utp-outbound-fallback.md).
