# Audit: hostile-input hardening, bugs, stale code, performance

## Goal
Make the app unable to crash, exhaust memory or fill the disk from hostile
torrents, peers, trackers or web seeds; fix the bugs the read-through found;
remove dead code; and speed up the paths that scale badly (large multi-file
torrents, resume verification). Found by reading all of `Packages/Core` and
`Packages/Domain`; `Features` and `App` were not audited in depth.

## Steps
Every fix starts with a failing regression test. One commit per step.

**Crashes and resource exhaustion (hostile input)**
- [x] 1. Bencode: cap nesting depth (~64). A deeply nested `llll…` from any
      tracker, DHT node, PEX peer or metadata blows the 512 KB task stack.
- [x] 2. Metainfo validation: reject negative file lengths, overflow in the size
      sum (traps today), `piece length` above a sane cap (allocates
      `Data(count: pieceLength)` per piece), and a piece-hash count that does not
      match `ceil(totalSize / pieceLength)` (negative last-piece length traps).
- [x] 3. Peer wire memory: `downloadPieces` parses bitfields with no piece count
      (1 MiB bitfield -> ~8M-entry set per peer) and accepts `have` indices
      beyond the torrent; metadata pieces are not capped at 16 KiB (a hostile
      peer can make `fetchMetadata` buffer ~640 MiB); block `begin`/length are
      not checked against the request grid.
- [x] 4. Snub/idle timers reset on any message, so a peer sending keep-alives or
      `have`s forever pins a worker slot (and the metadata loops). Base the
      timeout on the last data block, and bound `readMetadataPiece` by a deadline.
- [x] 5. Bounded network bodies: HTTP tracker reply, exact-source `.torrent`,
      web-seed range/segment (`session.data` buffers the whole body; a `200` to
      a range request downloads the entire file into memory). Sequential web
      seed keeps writing past `file.length` (disk fill).
- [x] 6. Peer address hygiene: drop loopback/unspecified/multicast/broadcast
      endpoints from trackers, PEX and DHT; cap `PeerSupply` growth (PEX can
      feed it without bound).

**Bugs**
- [x] 7. Single-file web seed: BEP 19 uses a `url-list` entry without a trailing
      `/` as-is; we always append the file name (`.../x.iso/x.iso` -> 404).
      Confirm with a test before changing.
- [x] 8. `verifiedPieces` is not cancellable: pausing or removing during a
      resume hash scan blocks until the scan finishes (folded into step 10).

**Stale code**
- [x] 9. Remove unused `PeerWireClient.currentAvailability`, `isEncrypted`,
      `RateLimiter.currentLimit`, `TorrentMetainfo.displaySize`,
      `TorrentLayout.fileCount`, `TorrentFileWriter.preparePartialFile`. Fix
      doc comments that contradict the code (tracker port, see Open questions).

**Performance** (baseline with `swiftorrent-bench` / a synthetic many-file
fixture first; drop a step if the gain is under ~5%)
- [x] 10. `TorrentFileWriter.write/read` recompute file offsets with a prefix sum
      per file per piece (O(files^2) per piece); use `TorrentLayout` offsets
      with binary search. Hash resume verification across cores and check
      cancellation. Same O(pieces x files) in `boundaryNeighborSlices`.
- [-] 11. Sequential web seed iterates `AsyncBytes` one byte at a time with a
      cancellation check per byte; read in chunks.
- [x] 12. Throttle progress to the main actor (<= 10 Hz). Today every verified
      piece sends an all-files snapshot and rebuilds a dictionary on the main
      thread.
- [x] 13. Read/parse `.torrent` files and restore the session off the main
      actor (the `Task` in `TorrentSession` inherits `@MainActor`).
- [x] 14. Measure-first, likely skip: per-operation `withTimeout` task groups on
      every socket read; `PieceDownloadCoordinator.nextPiece` O(pending) per
      claim; MSE modexp uses bitwise division (~0.1 s CPU per handshake).

**Guard**
- [x] 15. Seeded mutation (fuzz) tests: `BencodeParser`, `TorrentMetainfoParser`,
      `UTPPacket.init?`, `UTPConnectionCore.receive`, DHT/PEX/compact-peer
      parsers, `MagnetLinkParser`. Must never trap and must finish in bounded
      time.

## Minor, noted but not scheduled
Fold into a step above if touched anyway; otherwise leave.
- Bencode integers accept `+5`, `-0` and leading zeros (non-canonical, harmless).
- Tracker peer lists in dictionary form may carry hostnames, which get DNS-resolved.
- `xs=` exact-source URLs may point at localhost/LAN (GET only, body capped by step 5).
- Web-seed 206 replies are not checked against `Content-Range`; wrong bytes are
  only caught later by SHA-1 verification.
- Two torrent files can map to the same path, and a file `x.tor` collides with
  the partial of file `x`.
- `PieceDownloadCoordinator.availabilityCounts` only grows (never decremented
  when a peer leaves), so rarest-first ordering drifts over a long session.
- Endgame duplicates are written to disk before the first-completion check
  (harmless double write).
- DHT transaction IDs are 2 bytes (weak against spoofed replies; replies are
  still bencode-validated and bounded).
- `PeerWireClient` input buffer does `removeFirst` plus a `Data` copy per message,
  and RC4 round-trips `Data`/`[UInt8]`; candidates for step 14 if the bench
  shows CPU-bound transfers.
- Tracker/DHT UDP send/receive use bare continuations rather than `ResumeOnce`
  (Network.framework calls each completion once, so low risk).
- Session deletion, directory pruning and `items.first(where:)` per progress
  tick run on the main actor.
- `.torrent` files are read with no size cap.

## Scope changes
- 2026-10-14, step 6: loopback peers are kept (the swarm tests and local swarms use
  127.0.0.1); only unspecified, multicast, broadcast and reserved addresses drop.
- 2026-10-14, step 8: folded into step 10 (`verifiedPiecesConcurrently` is cancellable).
- 2026-10-14, step 10: 16,000 one-KB files: write 13.9 s -> 3.2 s, verify 34.6 s -> 1.1 s.
- 2026-10-14, step 11: skipped. `AsyncBytes` measured at ~50 MiB/s (one core) on
  the in-process stub; only the sequential fallback uses it, and the segmented
  path covers servers that honor `Range`. Revisit if a real server is faster.
- 2026-10-14, step 13: only `.torrent` parsing moved off the main actor; session
  restore at launch stays synchronous so the list is populated before the UI appears.
- 2026-10-14, step 14: MSE handshake measured at 8.9 ms (left). Piece claims
  at 100k pieces were 2.5 ms; now a one-pass scan over a flat counts array.
  Per-read `withTimeout` task groups were not measured and are left.

## Open questions
- Tracker `port`: decision 0002 and `docs/FEATURES.md` say `port=0`, but
  `TrackerRequest` defaults to 6881, no caller overrides it, and a test
  (`trackerRequestPort`) asserts 6881. We announce a port we never listen on.
  Pick one: make the code `port=0` per the decision, or amend the decision.

## Done when
- Each step has its regression test (steps 1-7, 10-13) and the three package
  test suites pass in Release.
- Fuzz tests (step 15) pass with a fixed seed.
- By hand: add a real torrent and a magnet, pause/resume mid-download, remove
  during a resume scan; speed on `Fixtures/big-buck-bunny.torrent` is no worse
  than the numbers in `docs/BENCHMARK.md`.

## Verified fine (no change needed)
Output path containment (`outputURL`), uTP packet/extension bounds and
reorder buffer, MSE resync cap and pad limit, wire-message length cap,
metadata hash check before parse, piece hash check before write, resume
continuation guards (`ResumeOnce`), rate limiter, session persistence and
delete-containment checks.
