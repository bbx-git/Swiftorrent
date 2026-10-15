# 0010 Shared connection budget, patient magnet resolve

## Context
With several torrents running, each wanted up to 100 peer sockets (TCP + a raced uTP socket) and a new magnet added 64 more probes. A Finder-launched app has 256 descriptors; everything failed with "Too many open files" and the add window showed "The network operation timed out." A hard 90 s resolve deadline also turned any slow swarm into an error, which other clients never do.

## Decision
- `FileDescriptorLimit.raise()` lifts the soft limit to 10,240 at launch.
- `ConnectionBudget.swarm` (300) caps peer connections across all torrents, FIFO so busy torrents interleave. `ConnectionBudget.resolve` (128) is a separate pool, so adding a magnet is never starved by running downloads.
- Magnet resolve has no deadline: discovery rounds repeat every 30 s with a status line (last error, elapsed time) until metadata arrives or the user cancels.
- Speed comes from live bytes (verified + received); the bar stays verified-only.

## Consequences
- A dead magnet spins until cancelled instead of failing; the status says why.
- 300 and 128 are fixed; revisit if many large swarms are routinely run together.
