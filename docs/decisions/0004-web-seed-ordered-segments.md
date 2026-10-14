# 0004 Web-seed files fetched as ordered range segments

## Context
A single HTTP stream per file left web-seed torrents at ~10.8 MiB/s (BBB), behind aria2c. Resume is size-based: `partialFileResumeOffset` treats the partial file's size as a contiguous prefix.

## Decision
Fetch the missing tail of each file as 1 MiB `Range` requests, 8 in flight, and write them strictly in order. A server answering `200` instead of `206` sends the file down the old single-stream path.

## Consequences
- The partial file is always a contiguous prefix, so resume and the size check stay correct. Writing out of order (sparse) would break both.
- BBB average 10.8 -> 18.0 MiB/s.
- Progress and rate-limiting advance per written segment, not per 64 KiB.
