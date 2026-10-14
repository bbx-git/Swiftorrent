# 0007 Hostile-input limits

## Context
Torrent files, magnet metadata, peers, trackers, DHT nodes and web seeds are all
untrusted. Before this audit a crafted input could trap (nested bencode, summed
file lengths), exhaust memory (bitfields, metadata pieces, buffered HTTP bodies)
or fill the disk (web seed streaming past the file length).

## Decision
Bound everything at the parser or I/O edge: bencode depth 64, piece length
<= 128 MiB, piece count must match size, peer availability limited to the piece
count, metadata pieces exactly 16 KiB, blocks on the request grid, snub timeout
anchored on the last data block, HTTP bodies capped by `BoundedHTTPClient`
(derived from the injected session's configuration), swarm reserve <= 5,000.
Tracker `port` is 0, as decision 0002 says.

## Consequences
- Loopback peers are still accepted (local swarms, tests); only undialable
  ranges (0/8, 224/4 and up) are dropped.
- The sequential web-seed fallback still reads `AsyncBytes` per byte (~50 MiB/s
  measured, one core); the segmented path covers servers that honor `Range`.
- New network-facing parsers need a mutation case in `FuzzTests`.
