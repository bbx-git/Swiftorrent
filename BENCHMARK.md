# Download-Speed Benchmark

How to measure Swiftorrent's download engine and compare it head-to-head against
two mainstream CLI torrent clients (**aria2c**, **transmission-cli**). Designed to
be re-run quickly from a cold session.

> **Why this exists:** Swiftorrent is GUI-only with no headless entry point, so we
> added `swiftorrent-bench` — a thin executable that drives the *real* engine
> (`SwiftorrentCore.TorrentDownloader`) and prints machine-readable throughput.
> It depends only on `SwiftorrentCore` (pure Foundation), so **it builds and runs
> without full Xcode** — unlike the SwiftUI app.

---

## Quick re-run (TL;DR)

```bash
# 0. one-time: reference clients
brew install aria2 transmission-cli

# 1. build the harness (no Xcode needed — Core-only target)
swift build -c release --product swiftorrent-bench

# 2. run all three clients back-to-back on a torrent or magnet
Scripts/benchmark.sh big-buck-bunny.torrent bbb                 # in-repo, web-seed heavy
Scripts/benchmark.sh /tmp/debian-13.6.0-amd64-netinst.iso.torrent debian   # real swarm
```

`Scripts/benchmark.sh <torrent-or-magnet> [label]` runs Swiftorrent, aria2c, then
transmission-cli **sequentially** (never in parallel — they'd compete for
bandwidth), each into a fresh temp dir (cold cache), and prints each one's wall
time / time-to-first-byte / speed.

---

## Test assets

- **In-repo (web-seed dominated):** `big-buck-bunny.torrent` (263.6 MiB). Reproducible
  but NOT a clean swarm test — Swiftorrent and aria2 pull it from the fast HTTP web
  seed, transmission ignores the web seed and uses the (slow) peer swarm. Good for a
  smoke test, misleading for swarm throughput.
- **Real peer swarm (the trustworthy comparison):** a well-seeded Linux ISO. Grab the
  current Debian netinst torrent (no web seed → pure swarm):

  ```bash
  curl -sSL -o /tmp/debian-13.6.0-amd64-netinst.iso.torrent \
    "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-13.6.0-amd64-netinst.iso.torrent"
  ```
  (Bump the version if `current/` has moved on; list the dir to check.)

Per project rules, don't assume other sample files exist on disk — use these or ask.

---

## Running the harness directly

```bash
.build/release/swiftorrent-bench --torrent <path>   [--dest <dir>] [--label <name>]
.build/release/swiftorrent-bench --magnet  "<uri>"  [--dest <dir>] [--label <name>]
```
Output is line-buffered, so progress streams live even when piped to a file. It
logs, once per second: elapsed, %, downloaded/total, instantaneous MiB/s, average
MiB/s — then a summary with **time-to-first-byte, average, and 1-second peak**.
Source: `Tools/SwiftorrentBench/main.swift`.

### Manual reference-client commands (what the script runs)

```bash
# aria2c — auto-exits after download because of --seed-time=0
aria2c --seed-time=0 --dir=OUT --console-log-level=warn --summary-interval=5 \
       --file-allocation=none <torrent-or-magnet>

# transmission-cli — does NOT self-exit; time launch until the first "Seeding" line.
# Use a throwaway --config-dir (see caveats) so a stale default config can't make it
# exit instantly and so your real transmission config is untouched.
transmission-cli --config-dir /tmp/tr-cfg -w OUT <torrent-or-magnet>
```

---

## Methodology & caveats (read before trusting numbers)

- **Sequential only.** Running clients simultaneously splits bandwidth and invalidates
  the comparison. The script enforces this.
- **Compare the right metric.** Wall time is confounded by startup + shutdown. Prefer
  each tool's **download-phase throughput** and **time-to-first-byte (TTFB)** separately.
- **aria2 wall time is inflated** by a few seconds of post-download seeding/shutdown
  even with `--seed-time=0`; trust its self-reported "avg speed" line.
- **transmission won't stop on its own.** We time *launch → first "Seeding" line*
  (download complete). Its `-f <finish-script>` hook did **not** fire under
  transmission-cli 4.1.3, so don't rely on it. The script caps the wait (`TR_MAX_WAIT`,
  600 s) so an endgame stall can't hang the run.
- **Single trial = directional, not exact.** Swarm health varies minute to minute.
  Run 2-3 times and alternate which client goes first for anything conclusive.
- **zsh gotcha:** an unmatched glob (e.g. `rm tr-done-*`) aborts the whole command in
  zsh (`no matches found`). The script runs under `bash` to avoid this.
- **transmission-cli instant-exit gotcha:** if its **default** config dir holds stale
  lock/RPC state from a previous run, a new instance prints startup then immediately
  "shutting down" (~0.2 s) and reports a nonsense ~0.5 s time. Always pass a fresh
  `--config-dir` (the script uses a per-run temp dir). This also keeps your real
  transmission config untouched.

---

## Results — 2026-08-14 (single trial each, sequential)

Reference clients: aria2c 1.37.0, transmission-cli 4.1.3.

### Debian 13.6.0 netinst ISO — 755 MiB, pure peer swarm (the clean comparison)

| Client        | Wall  | TTFB   | Transfer rate | Peak       | Notes                                   |
|---------------|-------|--------|---------------|------------|-----------------------------------------|
| **Swiftorrent** | 27.3 s | 12.7 s | **~52 MiB/s** | **60.4 MiB/s** | fastest transfer; slow to start         |
| aria2c        | 18.1 s | ~2.5 s | 48 MiB/s      | ~48 MiB/s  | fastest end-to-end (quick start)        |
| transmission  | 102.3 s | 6.0 s | ~41 MB/s bulk | 41 MB/s    | **~60 s endgame stall** (98→100% @ 0 B/s) |

### big-buck-bunny.torrent — 263.6 MiB, web-seed dominated

| Client        | Wall/complete | TTFB  | Rate         | Source used            |
|---------------|---------------|-------|--------------|------------------------|
| **Swiftorrent** | 24.5 s       | 0.5 s | avg 10.8 MiB/s, peak 17.7 | HTTP web seed |
| aria2c        | ~18-20 s      | ~1 s  | avg ~13 MiB/s | HTTP web seed          |
| transmission  | ~35-40 s      | ~6 s  | peak 28 MB/s | peer swarm (+ endgame stall) |

---

## Conclusions

1. **Swiftorrent's swarm transfer engine is already excellent — it beat both reference
   clients on raw throughput** (highest sustained ~52 MiB/s and highest 1 s peak
   60 MiB/s on the Debian swarm). The 100-connection pool + adaptive pipelining is
   doing its job.
2. **The one clear weakness is time-to-first-byte (~12.7 s).** Swiftorrent waits out
   the full `TorrentDownloader.peerDiscoveryDeadline = 12s` before starting the swarm,
   while aria2 is transferring in ~2.5 s. That startup gap is the *entire* reason aria2
   finished the Debian ISO ~9 s sooner. On smaller torrents this fixed cost dominates
   the whole download.
3. **Swiftorrent's endgame is healthy** — it ran at full speed through ~96% and finished
   cleanly. Transmission repeatedly stalled ~60 s on the final 2% (both torrents),
   which validates the endgame-`cancel` work already in `PieceDownloadCoordinator`.
4. **Web-seed throughput slightly trails aria2** (10.8 vs ~13 MiB/s on BBB), suggesting
   we use a single connection to a web seed where aria2 parallelizes.

## TODO / next session (in priority order)

- [ ] **Cut time-to-first-byte (highest value).** Start the swarm as soon as a small
      number of peers are in hand instead of waiting the full 12 s deadline. Levers in
      `SwiftorrentCore/TorrentDownloader.swift`: lower `peerDiscoveryDeadline` (12 s) and/or
      `enoughPeersToStart` (100), or begin downloading on the first ~10-20 peers and let
      the swarm supervisor's re-announce top the pool up. **Validate with
      `swiftorrent-bench` — this is a Core change, so no Xcode needed.** Target: TTFB
      < 4 s without hurting steady-state throughput.
- [ ] **Parallelize web-seed connections** (secondary) to close the ~13 vs 10.8 MiB/s
      gap on web-seed torrents. See `WebSeedDownloader`.
- [ ] **Make the benchmark statistically sound:** have `benchmark.sh` do N trials and
      alternate client order; report median. Currently single-trial/directional.
- [ ] **Optional:** teach `swiftorrent-bench` a `--strip-web-seeds` flag so BBB can be
      forced down the peer pipeline for an apples-to-apples swarm comparison with
      transmission on the same content.

## Blocker note

Full Xcode is currently uninstalled (`xcode-select -p` → CommandLineTools), so the
**SwiftUI app can't be built or deployed** (SwiftUI macros missing) — but the bench
harness and any `SwiftorrentCore` engine change build and run fine. Reinstall Xcode +
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to restore app
build/deploy. See `SESSION_STATE.md`.
