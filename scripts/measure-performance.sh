#!/bin/bash
# Measure the performance numbers BerryDB publishes, so they can be checked
# rather than trusted.
#
# Usage:  scripts/measure-performance.sh [runs]      (default 5)
#
# Requires a release build: run `make app` first.
#
# Two numbers get confused often enough that this reports both separately:
#
#   process spawn   - the moment the process exists. Small, and NOT what a user
#                     experiences. A launch-time claim built on this reads far
#                     better than the app actually feels.
#   first window    - the moment a window is on screen. This is cold start.
#
# The window timing goes through System Events, which needs Accessibility
# permission for your terminal (System Settings > Privacy & Security >
# Accessibility). Without it the script still reports everything else and says
# the window timing was unavailable.
set -uo pipefail

RUNS="${1:-5}"
APP="dist/BerryDB.app"
BIN="$APP/Contents/MacOS/BerryDB"
PATTERN='BerryDB.app/Contents/MacOS/BerryDB'

[ -d "$APP" ] || { echo "No $APP — run 'make app' first." >&2; exit 1; }

# Resident memory depends heavily on how much local data has accumulated, so
# report the store size next to it. Without this the RAM figure means nothing.
STORE="$HOME/Library/Application Support/BerryDB/store.sqlite"
STORE_MB=0
[ -f "$STORE" ] && STORE_MB=$(( $(stat -f%z "$STORE") / 1048576 ))

now() { python3 -c 'import time;print(time.time())'; }
median() { printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END{print (NR%2) ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2}'; }

# Machine conditions decide whether any of the numbers below mean anything. Under
# memory pressure the OS pages constantly, so resident size tracks the pressure
# rather than the app, and cold start is dominated by page-ins. Measured once on a
# machine with swap 93% full, cold start ranged 750-4390 ms and idle memory
# 116-210 MB for the same build — all of it noise.
SWAP_TOTAL=$(sysctl -n vm.swapusage | sed -E 's/.*total = ([0-9.]+)M.*/\1/')
SWAP_USED=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')
SWAP_PCT=$(python3 -c "print(f'{float('$SWAP_USED')/max(float('$SWAP_TOTAL'),1)*100:.0f}')")
LOAD1=$(sysctl -n vm.loadavg | awk '{print $2}')
CORES=$(sysctl -n hw.ncpu)
BUSY=""
python3 -c "import sys;sys.exit(0 if float('$LOAD1') > float('$CORES')*0.5 else 1)" && BUSY="load"
[ "$SWAP_PCT" -gt 25 ] 2>/dev/null && BUSY="${BUSY:+$BUSY and }swap"

echo "BerryDB performance measurement"
echo "==============================="
echo "machine : $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "memory  : $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
echo "macOS   : $(sw_vers -productVersion)"
echo "app     : $(du -sk "$APP" | awk '{printf "%.1f MB", $1/1024}')"
echo "binary  : $(ls -l "$BIN" | awk '{printf "%.1f MB", $5/1048576}')"
echo "store   : ${STORE_MB} MB   <- resident memory scales with this"
echo "load    : ${LOAD1} over ${CORES} cores"
echo "swap    : ${SWAP_USED} of ${SWAP_TOTAL} MB used (${SWAP_PCT}%)"
echo "runs    : $RUNS"
echo

if [ -n "$BUSY" ]; then
    echo "REFUSING TO MEASURE: this machine is busy ($BUSY)."
    echo
    echo "  Under memory pressure the OS pages constantly, so resident size follows"
    echo "  the pressure rather than the app, and cold start is dominated by"
    echo "  page-ins. Numbers taken now would be noise presented as data."
    echo
    echo "  Close what you can (containers, editors, browsers), let memory settle,"
    echo "  and run again. Pass --anyway to override and get numbers you should not"
    echo "  publish."
    [ "${2:-}" = "--anyway" ] || exit 2
    echo "  --anyway given; continuing under load. Do not publish these."
    echo
fi

SPAWNS=(); WINDOWS=(); RSSES=()

for i in $(seq 1 "$RUNS"); do
    pkill -f "$PATTERN" 2>/dev/null
    sleep 2
    T0=$(now)
    open "$APP"

    PID=""
    for _ in $(seq 1 400); do
        PID=$(pgrep -f "$PATTERN" | head -1)
        [ -n "$PID" ] && break
        sleep 0.02
    done
    [ -z "$PID" ] && { echo "run $i: app did not start" >&2; continue; }
    SPAWN=$(now)

    WIN=""
    for _ in $(seq 1 400); do
        N=$(osascript -e 'tell application "System Events" to try
  count windows of process "BerryDB"
on error
  0
end try' 2>/dev/null)
        if [ "${N:-0}" -ge 1 ] 2>/dev/null; then WIN=$(now); break; fi
        sleep 0.05
    done

    # Let it settle before reading memory, so this is idle and not still launching.
    sleep 10
    RSS=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')

    SPAWN_MS=$(python3 -c "print(f'{(float('$SPAWN')-float('$T0'))*1000:.0f}')")
    RSS_MB=$(python3 -c "print(f'{int('${RSS:-0}')/1024:.1f}')")
    SPAWNS+=("$SPAWN_MS"); RSSES+=("$RSS_MB")
    if [ -n "$WIN" ]; then
        WIN_MS=$(python3 -c "print(f'{(float('$WIN')-float('$T0'))*1000:.0f}')")
        WINDOWS+=("$WIN_MS")
        printf 'run %d:  spawn %5s ms   window %5s ms   idle %6s MB\n' "$i" "$SPAWN_MS" "$WIN_MS" "$RSS_MB"
    else
        printf 'run %d:  spawn %5s ms   window     ?      idle %6s MB\n' "$i" "$SPAWN_MS" "$RSS_MB"
    fi
done

# One extra launch for the leak check: `leaks` needs a live process, and the
# loop above kills each one.
pkill -f "$PATTERN" 2>/dev/null; sleep 2
open "$APP"; sleep 12
LEAK_PID=$(pgrep -f "$PATTERN" | head -1)
LEAK_LINE="(not measured)"
OWN_LEAKS="?"
if [ -n "$LEAK_PID" ]; then
    LEAK_OUT=$(leaks "$LEAK_PID" 2>/dev/null)
    LEAK_LINE=$(printf '%s' "$LEAK_OUT" | grep -E 'leaks for' | head -1)
    # Leaks inside Apple's frameworks are not ours to fix; what matters is
    # whether any allocation traces back into BerryDB's own code. Match only
    # Swift mangled symbols ($s<len>Berry...) — matching the plain string
    # "BerryDB" also hits the bundle path in every stack and always reports 1.
    OWN_LEAKS=$(printf '%s' "$LEAK_OUT" | grep -cE '\$s[0-9]+Berry' || true)
fi
pkill -f "$PATTERN" 2>/dev/null

echo
echo "medians"
echo "-------"
[ ${#SPAWNS[@]}  -gt 0 ] && printf 'process spawn : %8.0f ms  (not user-visible)\n' "$(median "${SPAWNS[@]}")"
if [ ${#WINDOWS[@]} -gt 0 ]; then
    printf 'first window  : %8.0f ms  <- cold start\n' "$(median "${WINDOWS[@]}")"
else
    echo 'first window  :        ?     <- grant Accessibility to your terminal and re-run'
fi
[ ${#RSSES[@]}   -gt 0 ] && printf 'idle memory   : %8.1f MB  (with a %s MB store)\n' "$(median "${RSSES[@]}")" "$STORE_MB"
echo "leaks         : $LEAK_LINE"
echo "  traced into BerryDB's own code: $OWN_LEAKS"
echo
echo "Streaming throughput and memory are measured separately by 'make bench',"
echo "which needs the Docker matrix up (see Tests/docker/compose.yml)."
