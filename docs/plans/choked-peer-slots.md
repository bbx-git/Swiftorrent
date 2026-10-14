# Choked peers holding slots

## Goal
Find out whether peers that choke us forever take up connection slots, and stop it if they do. Today the 90 s idle timeout restarts on every message, so a choked peer that keeps sending HAVEs or keep-alives never loses its slot. In a thin swarm, peers like that could fill all 100 slots and stall the download while untried peers wait in the reserve.

## Steps
- [ ] **Measure.** `PeerWireClient` reports choke/unchoke to the swarm; `TorrentDownloadProgress` gets an `unchokedPeers` count next to the connected count. The bench prints it on each 1 s line (`peers 87, unchoked 12`). The app status text stays the same.
- [ ] **Bench run.** Big Buck Bunny with `--strip-web-seeds`, plus 2–3 thin-swarm Internet Archive torrents saved in `Fixtures/` (legal content only, no copyrighted torrents; downloads go to `--dest tmp/…`). Record connected/unchoked over time and how big the reserve is in `docs/BENCHMARK.md`. If choked peers never fill the slots, stop here: write down the finding and close the open problem.
- [ ] **Fix (only if measured).** A peer that has stayed choked for `chokeTimeout` (around 60 s) is dropped when the reserve has untried peers, so a choked peer gives way only when there is someone to replace it. Regression test first: a fake transport that chokes and sends a HAVE every 10 s must be dropped after the timeout, and kept when the reserve is empty. Decision doc `0009`.

## Done when
- Tests: the existing suite passes; step 3 adds a `ChokedPeerTimeoutTests` regression test.
- By hand: a bench run shows the unchoked count; with the fix, the unchoked share in a thin swarm goes up (numbers in `BENCHMARK.md`).

2026-10-14: plan written and baseline tests pass. Not approved yet: the user still has to confirm the plan and the use of archive.org fixtures before step 1 starts.
