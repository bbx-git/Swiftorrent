# 0006 uTP as an outbound fallback

## Context
Some peers don't answer on TCP but do on uTP (BEP 29). A probe over 758 listed peers found 100 answering TCP, 117 uTP and 44 uTP only (+44% reachable peers). Download-only policy (0002) rules out a listener.

## Decision
Outbound uTP only, one UDP `NWConnection` per peer, tried once after a TCP connect failure (5 s cap); reconnects of that peer then stay on uTP. The sender is minimal (fixed 64 KiB window, RTO plus fast retransmit, no LEDBAT); the receiver is complete (reorder buffer, selective ACK, honest window, echoed delay).

## Consequences
- Measured on Debian and Big Buck Bunny (web seeds stripped): no speed-up, since TCP-reachable seeds are faster; one of five BBB runs had a 15 s tail with 36 pieces over uTP. Forced uTP works (756 MiB verified, 1.5-4x slower than TCP).
- If the tail shows up again, deprioritise uTP peers in piece assignment rather than removing the fallback.
- No inbound uTP: peers that only dial in stay unreachable (0002).
- `PeerWireClient.defaultTransportPolicy` exists for the bench only.
