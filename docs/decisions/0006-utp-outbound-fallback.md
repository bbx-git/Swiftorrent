# 0006 uTP as an outbound fallback

## Context
Some peers don't answer on TCP but do on uTP (BEP 29). A probe over 758 listed peers found 100 answering TCP, 117 uTP and 44 uTP only (+44% reachable peers). Download-only policy (0002) rules out a listener.

## Decision
Outbound uTP only, one UDP `NWConnection` per peer. TCP gets a 1 s head start (or until it fails), then uTP is tried alongside it and the first one ready wins (`openFirst`); reconnects of a uTP peer stay on uTP. 2026-10-14: was "uTP only after TCP fails", which made every uTP-only peer wait out the TCP timeout (~40% of reachable peers in a public swarm, see `docs/BENCHMARK.md`, "Magnet slow start"). The sender is minimal (fixed 64 KiB window, RTO plus fast retransmit, no LEDBAT); the receiver is complete (reorder buffer, selective ACK, honest window, echoed delay).

## Consequences
- Measured on Debian and Big Buck Bunny (web seeds stripped): no speed-up, since TCP-reachable seeds are faster; one of five BBB runs had a 15 s tail with 36 pieces over uTP. Forced uTP works (756 MiB verified, 1.5-4x slower than TCP).
- If the tail shows up again, deprioritise uTP peers in piece assignment rather than removing the fallback.
- No inbound uTP: peers that only dial in stay unreachable (0002).
- `PeerWireClient.defaultTransportPolicy` exists for the bench only.
