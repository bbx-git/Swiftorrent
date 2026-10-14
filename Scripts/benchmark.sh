#!/bin/bash
#
# benchmark.sh — compare Swiftorrent's download engine against aria2c and
# transmission-cli on the same torrent/magnet, back-to-back (sequential, so the
# clients never compete for bandwidth). Each run uses a fresh temp directory
# (cold cache) that is cleaned up on exit.
#
# Usage:
#   Scripts/benchmark.sh <torrent-path | magnet-uri> [label]
#
# Examples:
#   Scripts/benchmark.sh Fixtures/big-buck-bunny.torrent bbb
#   Scripts/benchmark.sh Fixtures/local/debian-13.6.0-amd64-netinst.iso.torrent debian
#   Scripts/benchmark.sh "magnet:?xt=urn:btih:..." mymagnet
#
# Prereqs (see docs/BENCHMARK.md):
#   - swiftorrent-bench built:  swift build -c release --product swiftorrent-bench
#     (this builds WITHOUT full Xcode — it only depends on SwiftorrentCore)
#   - brew install aria2 transmission-cli
#
# Run under bash (the shebang forces it) so the shell globbing/timeout logic is
# consistent regardless of the user's login shell.
set -u

SRC="${1:?usage: benchmark.sh <torrent-path-or-magnet> [label]}"
LABEL="${2:-bench}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/.build/release/swiftorrent-bench"
TR_MAX_WAIT=600   # seconds — give up on a transmission endgame stall after this

if [ ! -x "$BENCH" ]; then
    echo "error: $BENCH not found. Build it first:" >&2
    echo "  swift build -c release --product swiftorrent-bench" >&2
    exit 1
fi

WORK="$(mktemp -d /tmp/sw-bench.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
if [[ "$SRC" == magnet:* ]]; then SWFLAG=--magnet; else SWFLAG=--torrent; fi

hr() { printf '\n============ %s ============\n' "$1"; }
elapsed() { echo "$(date +%s.%N) - $1" | bc; }

# ---- 1. Swiftorrent (prints its own TTFB / avg / peak summary) ----
hr "swiftorrent-bench"
"$BENCH" $SWFLAG "$SRC" --label "sw-$LABEL" --dest "$WORK/sw"

# ---- 2. aria2c (auto-exits with --seed-time=0; reports its own avg speed) ----
hr "aria2c"
mkdir -p "$WORK/aria2"
a_start=$(date +%s.%N)
aria2c --seed-time=0 --dir="$WORK/aria2" --console-log-level=warn \
       --summary-interval=5 --file-allocation=none "$SRC" 2>&1 \
    | grep -E "avg speed|\|OK  \|" | sed 's/^/  /'
echo "  aria2c wall (incl. shutdown): $(elapsed "$a_start")s"

# ---- 3. transmission-cli (won't self-exit; time launch -> first "Seeding") ----
hr "transmission-cli"
mkdir -p "$WORK/tr" "$WORK/tr-cfg"
LOG="$WORK/tr.log"
t_start=$(date +%s.%N); t_fb=""
# Use a per-run --config-dir: transmission-cli exits immediately at startup if its
# default config dir holds stale lock/RPC state from a previous run. Isolating it
# also avoids touching the user's real transmission configuration.
transmission-cli --config-dir "$WORK/tr-cfg" -w "$WORK/tr" "$SRC" > "$LOG" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    if [ -z "$t_fb" ] && grep -qE "Progress: [1-9]" "$LOG" 2>/dev/null; then t_fb=$(date +%s.%N); fi
    grep -q "Seeding" "$LOG" 2>/dev/null && break
    if (( $(echo "$(elapsed "$t_start") > $TR_MAX_WAIT" | bc) )); then
        echo "  (transmission exceeded ${TR_MAX_WAIT}s — likely endgame-stalled; giving up)"
        break
    fi
    sleep 0.5
done
t_end=$(date +%s.%N)
kill -TERM "$pid" 2>/dev/null
echo "  transmission wall (launch -> download complete): $(echo "$t_end - $t_start" | bc)s"
[ -n "$t_fb" ] && echo "  transmission TTFB: $(echo "$t_fb - $t_start" | bc)s"
peak=$(tr '\r' '\n' < "$LOG" | grep -oE '\([0-9.]+ [kM]B/s\)' | tr -d '()' \
       | awk '/MB/{v=$1*1024} /kB/{v=$1} {printf "%.0f %s\n", v, $0}' | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$peak" ] && echo "  transmission peak speed seen: $peak"

hr "done"
echo "See docs/BENCHMARK.md for how to read these numbers and the known caveats."
