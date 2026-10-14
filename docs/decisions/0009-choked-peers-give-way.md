# 0009: Choked peers give way to untried peers

## Context
`idleTimeout` (90 s) is a per-read timeout, so a peer that keeps us choked but sends HAVEs or keep-alives never loses its connection slot. In a thin swarm such peers could fill all slots while untried peers wait in the reserve. We could not measure it on a real swarm (archive.org torrents are web-seed-only); the behavior is proven with a loopback seed instead.

## Decision
- A peer that has kept us choked for `chokeTimeoutSeconds` (60 s) is dropped when `PeerSupply` has untried peers (`hasUntriedPeers`). Only an unchoke resets the clock.
- With an empty reserve the peer is kept. A timed-out read closes the socket, so the check runs before each read and bounds it only when someone is waiting; a silent peer still ends at `idleTimeout`.
- `TorrentDownloadProgress` carries `connectedPeers` and `unchokedPeers`; the bench prints them on each 1 s line.

## Consequences
- A healthy swarm is unaffected: unchoked peers never start the clock, and nothing is dropped without a replacement.
- Tests: `ChokedPeerTimeoutTests`.
- The real-world gain is not measured. If a thin swarm turns up, record connected/unchoked in `BENCHMARK.md`.
