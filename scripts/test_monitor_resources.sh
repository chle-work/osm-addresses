#!/usr/bin/env bash
# scripts/test_monitor_resources.sh — regression tests for the resource sampler
#
# Usage: ./scripts/test_monitor_resources.sh
#
# Covers the two properties that previous silent failures turned out to depend on:
#
#   1. --peak-since must filter samples chronologically, so that a per-layer
#      report attributes scratch consumption to the layer that caused it.
#   2. The unlinked-scratch detector must actually account for space that du(1)
#      cannot see. An earlier sampler degraded to a constant 0 because it shelled
#      out to ps(1), which the conversion image does not ship, and the failure
#      was invisible precisely because 0 is a plausible reading.
#
# A full conversion of the Monaco corpus finishes in under a second and yields
# one or two samples, so it cannot distinguish a working detector from a broken
# one. These tests therefore synthesise both conditions with known quantities.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="${SCRIPT_DIR}/monitor_resources.sh"

if [ ! -f "$MONITOR" ]; then
    echo "ERROR: sampler not found at $MONITOR"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" = "$actual" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS  ${label}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL  ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
    fi
}

# --- 1. Chronological filtering of --peak-since -----------------------------
#
# The fixture carries a deliberate dip: the highest unlinked reading sits in the
# last third, so a filter that ignored the timestamp would still report it for
# an early window and pass by accident. Each expectation below is therefore
# distinguishable from "returns the global maximum".

echo "--- --peak-since filters samples by timestamp ---"

FIXTURE="${TMP_DIR}/samples.csv"
cat > "$FIXTURE" <<'EOF'
timestamp,elapsed_s,disk_used_pct,disk_avail_mb,mem_avail_mb,swap_used_mb,proc_peak_rss_mb,unlinked_scratch_mb,a_mb,b_mb
2026-10-08T10:00:00Z,0,40,50000,3900,0,100,0,1,1
2026-10-08T10:00:15Z,15,45,47000,3800,0,900,4000,1,1
2026-10-08T10:00:30Z,30,55,41000,3700,0,1000,9000,1,1
2026-10-08T10:00:45Z,45,41,49000,3850,0,200,20,1,1
2026-10-08T10:01:00Z,60,60,38000,3600,0,1100,16223,1,1
2026-10-08T10:01:15Z,75,58,39000,3650,0,1050,14000,1,1
EOF

check "whole log" "16223 38000 6" "$(bash "$MONITOR" --peak-since "$FIXTURE" 2026-10-08T10:00:00Z)"
check "last two samples only" "16223 38000 2" "$(bash "$MONITOR" --peak-since "$FIXTURE" 2026-10-08T10:01:00Z)"
check "boundary is inclusive" "16223 38000 4" "$(bash "$MONITOR" --peak-since "$FIXTURE" 2026-10-08T10:00:30Z)"
check "window after last sample" "0 0 0" "$(bash "$MONITOR" --peak-since "$FIXTURE" 2026-10-08T10:09:00Z)"
check "absent log" "0 0 0" "$(bash "$MONITOR" --peak-since "${TMP_DIR}/missing.csv" 2026-10-08T10:00:00Z)"

# The decisive case: a window that starts at the final sample must report that
# sample's lower reading, not the global maximum one sample earlier. An
# implementation that ignored the timestamp would return 16223 here.
check "window excludes earlier peak" "14000 39000 1" "$(bash "$MONITOR" --peak-since "$FIXTURE" 2026-10-08T10:01:15Z)"

# --- 2. Unlinked scratch is detected ----------------------------------------
#
# Reproduces what the GDAL OSM driver does to its node cache: open a file, then
# unlink it while keeping the descriptor. The blocks stay allocated, the
# directory entry is gone, and du(1) reports nothing.

echo "--- unlinked scratch is detected and attributed ---"

PAYLOAD_MB=64
HOLDER_DIR="${TMP_DIR}/holder"
PAYLOAD="${TMP_DIR}/payload"
LIVE_LOG="${TMP_DIR}/live.csv"
mkdir -p "$HOLDER_DIR"

# conversion_pids() matches /proc/<pid>/comm against the conversion binaries, so
# the holder must carry one of those names to be considered at all.
cp /bin/sleep "${HOLDER_DIR}/duckdb"

# The holder is exec'd into a long-lived process that would otherwise inherit
# this script's stdout. That keeps the write end of a pipe open and makes any
# consumer of this script's output block waiting for EOF, so its descriptors
# are closed off here.
(
    exec 9>"$PAYLOAD"
    dd if=/dev/zero of=/proc/self/fd/9 bs=1M count="$PAYLOAD_MB" 2>/dev/null
    rm -f "$PAYLOAD"
    exec "${HOLDER_DIR}/duckdb" 30
) >/dev/null 2>&1 &
HOLDER_SHELL=$!

sleep 2

if [ -e "$PAYLOAD" ]; then
    echo "  SKIP  payload was not unlinked; test environment cannot express the condition"
else
    DU_MB="$(du -sm "$TMP_DIR" 2>/dev/null | cut -f1)"

    MONITOR_ECHO=0 MONITOR_FS=/ timeout 4 bash "$MONITOR" "$LIVE_LOG" 1 "$HOLDER_DIR" >/dev/null 2>&1 || true

    DETECTED_MB="$(awk -F, 'NR > 1 { if ($8 + 0 > peak) peak = $8 + 0 } END { print peak + 0 }' "$LIVE_LOG")"

    # du(1) is structurally unable to see the payload, which is the entire reason
    # the descriptor-based reading exists.
    if [ "${DU_MB:-0}" -lt "$PAYLOAD_MB" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS  du cannot see the payload (${DU_MB:-0} MB < ${PAYLOAD_MB} MB)"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL  du reported ${DU_MB:-0} MB; payload was expected to be invisible"
    fi

    # Allow a small tolerance: the sampler also counts any other unlinked
    # descriptors the process happens to hold.
    if [ "$DETECTED_MB" -ge "$((PAYLOAD_MB * 9 / 10))" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS  sampler detected ${DETECTED_MB} MB unlinked (expected about ${PAYLOAD_MB} MB)"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL  sampler detected ${DETECTED_MB} MB unlinked, expected about ${PAYLOAD_MB} MB"
        echo "        a constant 0 here is the known regression: the detector"
        echo "        depends only on /proc, so an external tool must not creep back in"
    fi
fi

kill "$HOLDER_SHELL" 2>/dev/null || true
wait "$HOLDER_SHELL" 2>/dev/null || true

# --- Result -----------------------------------------------------------------

echo "--- ${PASS_COUNT} passed, ${FAIL_COUNT} failed ---"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
