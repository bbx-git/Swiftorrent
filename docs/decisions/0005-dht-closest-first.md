# 0005 DHT lookup walks closest-first

## Context
Trackerless magnets resolved in 29-54 s or failed (3/5). The DHT walk was a FIFO over returned nodes in 8-wide batches that each waited for the slowest query, so the 80-query budget was spent wandering.

## Decision
Ask the node nearest the info-hash by XOR distance next (nodes without an id first), keep a sliding window of `parallelQueries`, re-seed from bootstrap routers up to twice when no peer was found, 3 s query timeout.

## Consequences
- 20/20 resolved, median 1.9 s (`docs/BENCHMARK.md`).
- Don't go back to batch-and-wait or an unsorted queue.
- Re-seeding repeats queries to the routers; bounded by `queryLimit`.
