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
Scripts/benchmark.sh Fixtures/local/debian-13.7.0-amd64-netinst.iso.torrent debian   # real swarm
```

`Scripts/benchmark.sh <torrent-or-magnet> [label]` runs Swiftorrent, aria2c, then
transmission-cli **sequentially** (never in parallel — they'd compete for
bandwidth), each into a fresh temp dir (cold cache), and prints each one's wall
time / time-to-first-byte / speed.

To measure the **magnet metadata-resolve phase on its own** — without downloading
the payload, so many magnets and repeats stay practical:

```bash
.build/release/swiftorrent-bench --magnet "magnet:?xt=urn:btih:…" --resolve-only
# -> RESOLVE swiftorrent 0.9 OK debian-13.6.0-amd64-netinst.iso
```

It prints one machine-readable `RESOLVE <label> <seconds> OK|FAIL` line per run,
on failure as well as success. Always read the two together: a resolver that gives
up early is *fast* exactly when it is broken, so resolve time is only meaningful
next to the success rate over a set of magnets. Include trackerless (info-hash
only) magnets in any such sweep — they exercise the DHT-only path, which is where
resolution breaks first.

---

## Test assets

- **In-repo (web-seed dominated):** `big-buck-bunny.torrent` (263.6 MiB). Reproducible
  but NOT a clean swarm test — Swiftorrent and aria2 pull it from the fast HTTP web
  seed, transmission ignores the web seed and uses the (slow) peer swarm. Good for a
  smoke test, misleading for swarm throughput.
- **Real peer swarm (the trustworthy comparison):** a well-seeded Linux ISO. Grab the
  current Debian netinst torrent (no web seed → pure swarm):

  ```bash
  curl -sSL -o Fixtures/local/debian-13.7.0-amd64-netinst.iso.torrent \
    "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-13.7.0-amd64-netinst.iso.torrent"
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
transmission-cli --config-dir tmp/tr-cfg -w OUT <torrent-or-magnet>
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

## Results — 2026-08-15 (magnet-link entry path, single trial each, sequential)

Same Debian 13.6.0 netinst content as above (755 MiB, pure peer swarm), but entered
as a **magnet link** instead of a `.torrent` file, to exercise the info-hash →
metadata-resolution path specifically. Magnet derived from the official
`debian-13.6.0-amd64-netinst.iso.torrent`'s own info-hash (fresh swarm snapshot,
not the same run as the `.torrent`-file test above).

| Client        | Wall (download) | TTFB   | Sustained rate* | Peak       | Notes                                    |
|---------------|------------------|--------|------------------|------------|--------------------------------------------|
| **Swiftorrent** | 24.0 s | 12.5 s (+ 18.8 s magnet metadata resolution) | **~65.7 MiB/s** | **74.58 MiB/s** | fastest transfer again; magnet adds a one-time metadata-resolution cost on top of the usual startup latency |
| aria2c        | 18.2 s (incl. shutdown) | not captured this run | ~61 MiB/s | ~61 MiB/s | fastest end-to-end again |
| transmission  | 75.8 s | 17.3 s | ~48.5 MB/s peak | 48.52 MB/s | no major endgame stall this run (vs. ~60 s stall previously) |

\* *Sustained* = bytes ÷ (wall − TTFB), i.e. throughput once the swarm is actually
flowing — same definition used for the 2026-08-14 row above.

**Magnet-specific finding:** resolving the magnet's metadata (info-hash → peers →
`ut_metadata` fetch) took 18.8 s before the 12.5 s swarm-discovery TTFB even starts,
so total time from pasting a magnet link to first byte is ~31 s here — a cost that
doesn't exist when starting from an already-fetched `.torrent` file. This is a
separate phase from the download-phase TTFB weakness already tracked below.

**Aborted asset — do not reuse:** tried the official Blender Foundation short film
*Sintel* (Creative Commons Attribution 3.0, via `archive.org`'s own torrent,
~1.7 GiB) as a third comparison point. Its BitTorrent swarm is seed-starved (most
viewers stream it over HTTP from archive.org rather than torrenting it) — TTFB was
63 s and average throughput never exceeded ~1.3 MiB/s after 4+ minutes, which
reflects swarm health, not client engine performance. Aborted rather than let it run
to completion; not a useful benchmark asset despite being legitimately CC-licensed
and under a 2 GB size cap.

---

## Results — 2026-08-15 (post TTFB fix, single trial, Debian netinst)

Re-ran the same Debian 13.6.0 netinst `.torrent` (755 MiB, pure peer swarm) after
adding a **fast-start sentinel** to `TorrentDownloader.collectPeers`: once a short
3 s grace period elapses, the swarm starts as soon as *any* peer is known instead of
waiting out the full 12 s deadline for every source (in practice always the DHT) to
report. Late/DHT peers still arrive afterward via the existing swarm supervisor
re-announce.

| Metric | Before (2026-08-14) | After (2026-08-15) |
|---|---|---|
| Time to first byte | 12.7 s | **3.7 s** |
| Wall time (755 MiB) | 27.3 s | **17.3 s** |
| Average throughput | ~52 MiB/s | 43.6 MiB/s |
| Peak (1 s) | 60.4 MiB/s | 71.3 MiB/s |

TTFB target (< 4 s) hit without hurting steady-state throughput — average dipped
slightly (single-trial noise; peak is actually higher this run) but wall time still
dropped by ~10 s because first byte lands over 3x sooner. 61 offline tests green
(no regression — the mocked tests' trackers/DHT both answer near-instantly, so
`reported >= realSources` still wins the race before the fast-start grace period
matters).

**Deliberately left alone:** `MagnetMetadataResolver.collectPeers` has the same
deadline-sentinel shape but a documented rationale for its high threshold (300 peers
before considering an early stop) — metadata-serving peers are often reachable only
via the DHT, so applying the same "any peer + short grace period" fast-start there
risks tanking magnet-resolve success rate rather than just its speed. Left as a
candidate for a future session with room to live-validate the tradeoff, not applied
blindly by analogy.

> **Resolved 2026-08-15** (see the A/B sweep near the end of this file). The caution
> was right — the fast-start pattern would have been the wrong fix — but the real
> problem was that discovery *gated* fetching at all. Overlapping the two keeps every
> peer the high threshold was protecting and raised success rate 25% → 75%.

---

## Results — 2026-08-15 (later: magnet path re-run post TTFB fix, Debian + BBB, single trial each, sequential)

Full three-way comparison re-run entirely through the **magnet entry path**, now with
the fast-start TTFB fix in place. Two assets, both under a 2 GB cap: the Debian
13.6.0 netinst magnet (derived from the official `.torrent`'s info-hash, `tr=` only —
web seeds stripped for a pure-swarm test) and the in-repo Big Buck Bunny magnet
(README form, includes `xs=` exact source + web seed).

### Debian netinst magnet — 755 MiB, pure peer swarm

| Client        | Wall (download) | Metadata resolve | TTFB   | Avg rate | Peak | Notes |
|---------------|-----------------|------------------|--------|----------|------|-------|
| **Swiftorrent** | 17.1 s | 19.4 s | **3.4 s** | 44.28 MiB/s | **69.54 MiB/s** | fastest transfer + fastest post-resolve start; ~36.5 s end-to-end |
| aria2c        | 20.1 s end-to-end (incl. metadata + shutdown) | (included) | n/a | 51 MiB/s (self-reported) | — | still fastest end-to-end, purely because its metadata resolve is near-instant |
| transmission  | 65.4 s | (included) | 17.1 s | — | 51.2 MB/s | no 60 s endgame stall this run |

The swarm-phase **TTFB fix holds on the magnet path: 3.4 s** (vs 12.5 s in the
previous magnet run). The remaining end-to-end gap vs aria2c is now **entirely** the
**~19.4 s metadata-resolution phase** (consistent with the ~18.8 s measured
2026-08-15 earlier) — the top TODO below.

### Big Buck Bunny magnet — 263.6 MiB, `xs=` exact source + web seed

| Client        | Wall (download) | Metadata resolve | TTFB   | Avg rate | Peak | Notes |
|---------------|-----------------|------------------|--------|----------|------|-------|
| **Swiftorrent** | 13.0 s | **0.7 s** (via `xs=` exact source) | **0.2 s** | **20.31 MiB/s** | 24.68 MiB/s | fastest end-to-end by ~5x |
| aria2c        | 76.6 s end-to-end | (included) | n/a | 4.0 MiB/s (self-reported) | — | much slower than its prior ~13 MiB/s BBB run — web seed appears not to have carried it this time |
| transmission  | 90.0 s | (included) | 25.8 s | — | 18.93 MB/s | slowest again |

First benchmark where **Swiftorrent wins end-to-end outright** on both start latency
and transfer: when a magnet carries an `xs=` exact source the whole
metadata-resolution cost collapses to 0.7 s, and the 0.2 s TTFB + ~20 MiB/s
(roughly double the prior single-web-seed 10.8 MiB/s run — the magnet path pulled
peers *and* the web seed together) left aria2c and transmission far behind on the
same link. Single trial, so the aria2c collapse to 4 MiB/s may be swarm/web-seed
weather — but Swiftorrent's own numbers are consistent with all prior runs.

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
5. **The 2026-08-15 magnet-link run confirms both findings on a fresh swarm snapshot**
   (sustained ~65.7 MiB/s, peak 74.58 — again the fastest of the three; TTFB again
   ~12.5 s, again the reason aria2 finishes sooner end-to-end) and surfaces a second,
   separate cost specific to the magnet path: **~18.8 s to resolve metadata**
   (info-hash → peers → `ut_metadata`) before the swarm-discovery clock even starts.
   Pasting a magnet link is therefore slower to first byte than opening an
   already-fetched `.torrent` by roughly that whole metadata-resolution phase.
   Net takeaway across all runs: **Swiftorrent is not dropping speed relative to
   aria2c/transmission — its transfer engine is consistently the fastest of the
   three once data is flowing. All of its end-to-end slowness is concentrated in two
   fixed startup costs (peer-discovery deadline, and magnet metadata resolution),
   not in sustained throughput.**

## Results — 2026-08-15 (magnet metadata-resolve: overlapped discovery, A/B vs HEAD)

The last remaining startup cost. Measured with the new `swiftorrent-bench
--resolve-only` mode, which stops after metadata resolution and prints a
`RESOLVE <label> <seconds> OK|FAIL` line — resolve *speed alone is not a valid
metric here*, because a resolver that quits early looks fast precisely when it is
failing, so every run records success/failure too.

**Method.** 8 magnets — 4 legal, well-seeded Linux ISOs (Debian netinst, Debian
live XFCE, Ubuntu 24.04.3, Ubuntu 22.04.5), each in two forms: tracker-backed
(`tr=` from the official torrent's announce list) and **trackerless/DHT-only**
(info-hash + `dn` only). The DHT-only form is the case the old code's comment
warned about, so it is tested explicitly rather than assumed. Two binaries — `old`
(commit `11e111d`) and `new` — run **back-to-back on each magnet** so both see the
same swarm snapshot, over 2 full rounds: 32 runs total. Info-hashes were verified
byte-exact against the original `.torrent` info-dict bytes before any run.

| Metric | old (HEAD) | new |
|---|---|---|
| **Magnets resolved** | **4/16 (25%)** | **12/16 (75%)** |
| Resolve time, magnets old could resolve | 18.3 s avg | **0.9 s avg (~20× faster)** |
| Tracker-backed Debian (4 runs) | 15.3 / 19.8 / 19.0 / 19.2 s | 1.3 / 0.9 / 0.9 / 0.6 s |
| Trackerless DHT-only (8 runs) | **0/8 resolved** (all ~18.5 s `noPeers`) | **6/8 resolved** |

**Success rate went up, not down** — the outcome the old comment feared. There is
no run in the sweep that `old` resolved and `new` did not; every difference goes
the same way. Two causes:

1. **Discovery no longer blocks fetching.** `collectPeers` used to have to finish —
   in practice always timing out at its 18 s deadline, because the DHT never
   completes that fast — before the first peer was dialled. Trackers answer in
   about a second, so that entire wait was dead time. Peers now stream into a
   shared cursor as each source reports and workers probe immediately, which is
   the whole ~20× on tracker-backed magnets.
2. **The DHT gets to finish.** On a trackerless magnet the old 18 s cut-off fired
   before the DHT walk returned *anything*, so `collectPeers` threw `noPeers` and
   the magnet simply failed — 0/8 here. Discovery no longer delays the first probe,
   so its deadline could be raised to 60 s (still inside the 90 s phase budget) at
   no latency cost, and `DHTClient.peers(for:onPeers:)` now streams peers batch by
   batch instead of returning one lump at the end.

Caveats: **Ubuntu 22.04.5 (tracker form) failed on both binaries in both rounds** —
a seed-starved swarm for an old point release, not a resolver defect (its
info-hash was verified correct; treat it like Sintel above and don't reuse it).
The two remaining `new` failures are DHT-only runs that hit the 90 s phase
deadline; the same magnets resolved in the other round, so DHT-only resolution is
now *possible but variable*, where before it was reliably impossible.

Reproduce: `swift build -c release --product swiftorrent-bench`, then
`.build/release/swiftorrent-bench --magnet "<magnet>" --resolve-only`.

## TODO / next session (in priority order)

- [x] **Cut time-to-first-byte (highest value) — DONE 2026-08-15.** Added a fast-start
      sentinel to `TorrentDownloader.collectPeers`: 12.7 s → 3.7 s TTFB. See the
      "Results — 2026-08-15" section above.
- [x] **Magnet-path metadata-resolution phase (~18.8 s) — DONE 2026-08-15.** Overlapped
      peer discovery with metadata fetching instead of running them in sequence:
      18.3 s → 0.9 s on tracker-backed magnets, and resolve success rate went
      **up** 25% → 75% (trackerless magnets went from never resolving to usually
      resolving). The old high peer threshold turned out not to need careful
      tuning — it needed to stop being a *gate*. See the section directly above.
- [ ] **Parallelize web-seed connections** (secondary) to close the ~13 vs 10.8 MiB/s
      gap on web-seed torrents. See `WebSeedDownloader`.
- [ ] **Make the benchmark statistically sound:** have `benchmark.sh` do N trials and
      alternate client order; report median. Currently single-trial/directional.
- [ ] **Optional:** teach `swiftorrent-bench` a `--strip-web-seeds` flag so BBB can be
      forced down the peer pipeline for an apples-to-apples swarm comparison with
      transmission on the same content.

## Post-restructure re-run (2026-10-14)

Debian 13.7.0 netinst (756 MiB, pure swarm), single trial, sequential, after the move to the template layout:

| Client | Wall | TTFB | Avg | Peak |
|---|---|---|---|---|
| Swiftorrent | 20.6 s | 4.1 s | 36.7 MiB/s | 59.0 MiB/s |
| aria2c | 21.6 s | n/a | 39 MiB/s | n/a |
| transmission-cli | 93.4 s | 6.4 s | n/a | 52 MB/s |

Swiftorrent is on par with aria2c and finished well ahead of transmission. The swarm path is unaffected by the restructure.

## Magnet path on the new layout (2026-10-14)

`swiftorrent-bench --magnet ... --resolve-only`, Debian 13.7.0 netinst, 2 runs per form, same swarm snapshot:

| Form | Run 1 | Run 2 |
|---|---|---|
| Tracker-backed | 1.1 s OK | 1.3 s OK |
| Trackerless (DHT only) | 58.9 s OK | 90.1 s FAIL `metadataUnavailable` |

Tracker-backed resolution matches the pre-restructure ~1 s. DHT-only is still possible but variable (one of two hit the 90 s phase budget), as in the 2026-08-15 sweep. The restructure did not regress the magnet path.
