# uTP (BEP 29) outbound transport

## Goal
Peers that don't answer on TCP (firewalled, TCP-throttled, uTP-preferring) become reachable by falling back to a uTP connection over UDP. Outbound only: no listener, so [decision 0002](../decisions/0002-download-only-policy.md) stands.

## Design
- **One UDP `NWConnection` per peer**, so no shared socket or connection-id demux. The uTP connection id is random per peer.
- **Receiver-side focus.** We are download-only, so we send only small messages (handshake, requests). The sender needs RTO retransmit and a small fixed window, not full LEDBAT. The receiver needs in-order delivery, a reorder buffer, selective ACK, and an honest `wnd_size`.
- **Transport seam in `PeerWireClient`.** The code already funnels I/O through `openConnection`, `send`, `fillInputBuffer`, `close`. Extract those into a small `PeerTransport` protocol with TCP (existing code, moved) and uTP implementations. MSE, the BitTorrent handshake and everything above stay unchanged.
- **Fallback policy:** TCP first; if TCP connect fails (not cancellation), retry once over uTP. Peers that accept TCP never touch uTP, so there is no regression risk for them.

## Steps
- [x] 1. `UTPPacket`: 20-byte header encode/decode, selective-ACK extension, unit tests.
- [x] 1b. **Gate:** bench option that sends a uTP SYN to peers whose TCP connect failed and counts ST_STATE replies. Continue only if a useful share (about 5-10% of the peer list or more) answers; otherwise stop, delete this plan and record why in `docs/decisions/`.
  - Result (2026-10-14, `swiftorrent-bench --utp-probe`, 2 runs each, tmp/utp-probe.log): 758 peers listed, 100 answer TCP, 117 answer uTP, 44 answer uTP only (5.8% of the list; +44% over TCP-reachable). Passes the lower bound; absolute numbers are small because most listed peers are dead on both.
- [ ] 2. `UTPConnection` state machine (SYN/STATE/DATA/FIN/RST, seq/ack, reorder buffer, selective ACK, RTO retransmit, window) driven through a `DatagramChannel` protocol; loopback tests with simulated loss, reorder and duplication.
- [ ] 3. Extract `PeerTransport` from `PeerWireClient` with a TCP implementation; existing tests pass unchanged, no behaviour change.
- [ ] 4. uTP transport on UDP `NWConnection`, TCP-then-uTP fallback in `connect()`; covers swarm and magnet metadata paths.
- [ ] 5. Bench flag to force uTP, live validation against the Debian torrent, docs (`FEATURES.md`, `ARCHITECTURE.md`), decision `0006`, delete this plan.

## Done when
- Packet and connection tests pass, including 10% loss plus reordering over the in-memory channel, and a transfer of several MB arrives byte-identical.
- All existing Core tests still pass (73 at start).
- By hand: `swiftorrent-bench` with uTP forced downloads and hash-verifies pieces from real peers; a normal run is no slower than before.

## Risks
- Real-world gain is uncertain: it only helps peers whose TCP fails but whose uTP answers. Step 5 measures how many peers that is; if it is near zero, say so and keep the code only if it stays small.
- Some peers expect uTP packets from a stable UDP source port; per-peer sockets satisfy that.
