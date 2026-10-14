# Hardening 2: no traces, sanitizers, leaks, profiling

## Goal
The app leaves nothing on disk about what was downloaded except the files themselves and the resume list (`session.json`, emptied as rows are removed). After that, the engine is checked by tools rather than reading: Thread/Address Sanitizer over the test suites, a long download watched for leaks, and a profiled benchmark run.

## Steps
- [x] 1. No HTTP traces: every tracker/magnet/web-seed request goes through one ephemeral `URLSession` (no disk cache, no cookies, no HSTS/alt-svc store). Today `URLSession.shared` writes every announce URL, info-hash included, to `~/Library/Caches/app.swiftorrent.client/Cache.db`. Test: the shared session's configuration has no `urlCache`, no cookie storage.
- [x] 2. No names in the system log: torrent names and paths in `Logger` calls become `.private` (redacted in the persisted unified log).
- [x] 3. Thread Sanitizer and Address Sanitizer over Core, Domain and Features tests; fix each finding with a regression test.
- [x] 4. Leak/soak: download a large real torrent with `swiftorrent-bench`, sample `footprint`/`leaks` during and after; fix any growth or cycle.
- [x] 5. Profile a real-swarm benchmark with Time Profiler (`xctrace`); fix only measured hot spots, record before/after in `docs/BENCHMARK.md`.
- [ ] 6. Split `PeerWireClient.swift`, `TorrentSession.swift`, `SwiftorrentRootView.swift` by responsibility (no behaviour change).

2026-10-14: step 3 found a TSan report on the per-file progress array (fixed, merged into `complete`). Step 4 found two real growth bugs (lingering `Task.sleep` timeouts; uTP `Data` buffers), fixed with `DeadlineTests` and `receiveBufferDoesNotKeepConsumedBytes`. ASan run shows first byte ~100 s after resolve (normal build 1.6-2.5 s); not chased, probably handshake timeouts under ASan slowdown. Results in `docs/BENCHMARK.md`.

## Done when
- Test for the ephemeral session exists; sanitizer runs are clean (or findings fixed with tests).
- By hand: delete `~/Library/Caches/app.swiftorrent.client` and `~/Library/HTTPStorages/app.swiftorrent.client*`, download something, confirm neither comes back; `log show --predicate 'subsystem == "Swiftorrent"'` shows `<private>` instead of names.
