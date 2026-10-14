# 0002 Download-only client

## Context
Swiftorrent is a personal downloader. Seeding adds a listener socket, NAT exposure and upload-handling code the app does not need.

## Decision
No listening port, tracker `port=0` and `uploaded=0`, no piece-upload handling, no seeding loop; a best-effort `stopped` announce is sent on completion. PEX is inbound-only: we consume peer lists and never advertise ourselves.

## Consequences
- Peers that only accept inbound connections stay unreachable.
- Any feature that needs a listener (uTP inbound, seeding) must revisit this decision first.
