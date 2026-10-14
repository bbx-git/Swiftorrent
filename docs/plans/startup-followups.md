# Startup follow-ups and Features tests

## Goal
Close the remaining open items from the benchmark TODO and give `Packages/Features` a test target, so UI-adjacent logic is covered like Core and Domain.

## Steps
- [x] Add `SwiftorrentFeaturesTests` target to `Packages/Features` with a first test over add-window state logic (needs a look at `AddTorrentWindow.swift` for what is testable without UI).
- [x] Record uTP and notarization (`Scripts/notarize.sh`) as future work in `docs/FEATURES.md`.
- [ ] Parallelize web-seed connections in `WebSeedDownloader` (BBB: 10.8 vs ~13 MiB/s). Regression-style test with a mocked HTTP source.
- [ ] `swiftorrent-bench --strip-web-seeds` for apples-to-apples swarm comparisons.
- [ ] `Scripts/benchmark.sh`: N trials, alternating client order, report median.

## Done when
- Features tests run via `swift test --package-path Packages/Features`.
- Web-seed change: Core tests green and BBB bench avg >= prior 10.8 MiB/s (checked by hand).
- Docs reflect each landed step.
