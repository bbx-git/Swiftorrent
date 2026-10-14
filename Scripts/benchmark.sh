#!/bin/bash
#
# benchmark.sh — compare Swiftorrent's download engine against aria2c and
# transmission-cli on the same torrent/magnet, back-to-back (sequential, so the
# clients never compete for bandwidth). Each run uses a fresh temp directory
# (cold cache) that is cleaned up on exit.
#
# Usage:
#   [TRIALS=3] Scripts/benchmark.sh <torrent-path | magnet-uri> [label]
#
# TRIALS (default 1) repeats the whole comparison; the client order alternates on
# every trial (so none always goes first) and the median wall time is reported.
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

mkdir -p "$ROOT/tmp"
WORK="$(mktemp -d "$ROOT/tmp/sw-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if [[ "$SRC" == magnet:* ]]; then SWFLAG=--magnet; else SWFLAG=--torrent; fi

hr() { printf '\n============ %s ============\n' "$1"; }
elapsed() { echo "$(date +%s.%N) - $1" | bc; }

TRIALS="${TRIALS:-1}"
sw_walls=(); aria_walls=(); tr_walls=()

# Each run_* prints its details and appends its wall time (seconds) to *_walls.
run_swiftorrent() {
    hr "swiftorrent-bench"
    rm -rf "$WORK/sw"
    out="$("$BENCH" $SWFLAG "$SRC" --label "sw-$LABEL" --dest "$WORK/sw" | tee /dev/stderr)"
    w=$(echo "$out" | awk '/wall time:/{gsub("s","",$3); print $3}')
    [ -n "$w" ] && sw_walls+=("$w")
}

# aria2c auto-exits with --seed-time=0 and reports its own avg speed.
run_aria2() {
    hr "aria2c"
    rm -rf "$WORK/aria2"; mkdir -p "$WORK/aria2"
    a_start=$(date +%s.%N)
    aria2c --seed-time=0 --dir="$WORK/aria2" --console-log-level=warn \
           --summary-interval=5 --file-allocation=none "$SRC" 2>&1 \
        | grep -E "avg speed|\|OK  \|" | sed 's/^/  /'
    w=$(elapsed "$a_start")
    echo "  aria2c wall (incl. shutdown): ${w}s"
    aria_walls+=("$w")
}

# transmission-cli won't self-exit; time launch -> first "Seeding".
run_transmission() {
    hr "transmission-cli"
    rm -rf "$WORK/tr" "$WORK/tr-cfg"; mkdir -p "$WORK/tr" "$WORK/tr-cfg"
    LOG="$WORK/tr.log"
    t_start=$(date +%s.%N); t_fb=""
    # Per-run --config-dir: transmission-cli exits immediately at startup if its
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
    w=$(echo "$t_end - $t_start" | bc)
    echo "  transmission wall (launch -> download complete): ${w}s"
    tr_walls+=("$w")
    [ -n "$t_fb" ] && echo "  transmission TTFB: $(echo "$t_fb - $t_start" | bc)s"
    peak=$(tr '\r' '\n' < "$LOG" | grep -oE '\([0-9.]+ [kM]B/s\)' | tr -d '()' \
           | awk '/MB/{v=$1*1024} /kB/{v=$1} {printf "%.0f %s\n", v, $0}' | sort -rn | head -1 | cut -d' ' -f2-)
    [ -n "$peak" ] && echo "  transmission peak speed seen: $peak"
}

median() {
    [ $# -eq 0 ] && { echo "n/a"; return; }
    printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}'
}

for trial in $(seq 1 "$TRIALS"); do
    hr "trial $trial of $TRIALS"
    if (( trial % 2 )); then order="run_swiftorrent run_aria2 run_transmission"
    else order="run_transmission run_aria2 run_swiftorrent"; fi
    for fn in $order; do $fn; done
done

hr "median wall time over $TRIALS trial(s)"
echo "  swiftorrent:  $(median "${sw_walls[@]}")s"
echo "  aria2c:       $(median "${aria_walls[@]}")s"
echo "  transmission: $(median "${tr_walls[@]}")s"
hr "done"
echo "See docs/BENCHMARK.md for how to read these numbers and the known caveats."
