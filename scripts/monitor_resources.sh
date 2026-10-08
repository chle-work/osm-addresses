#!/usr/bin/env bash
# scripts/monitor_resources.sh — resource sampler for PBF -> GeoParquet conversions
#
# Usage:
#   ./scripts/monitor_resources.sh <csv_log> <interval_seconds> [watch_dir ...]
#   ./scripts/monitor_resources.sh --summary <csv_log>
#
# Sampling mode appends one CSV row per interval describing filesystem usage,
# available memory, swap usage, the largest resident set size among the
# conversion processes, and the size of each watched directory. Summary mode
# prints the peak values recorded in an existing CSV log.
#
# Rationale: large extracts (US, Russia, Brazil) are bound by temporary disk
# space rather than CPU. When a hosted agent fills its root filesystem it stops
# responding and Azure DevOps reports "job abandoned" with no usable log tail,
# which makes disk exhaustion indistinguishable from an out-of-memory kill.
# Sampling into a file that is published as an artifact makes both failure
# modes observable after the fact.
#
# The filesystem reported in the disk columns defaults to "/" and can be
# overridden via the MONITOR_FS environment variable.

set -u

MONITOR_FS="${MONITOR_FS:-/}"

print_usage() {
    echo "Usage: monitor_resources.sh <csv_log> <interval_seconds> [watch_dir ...]"
    echo "       monitor_resources.sh --summary <csv_log>"
}

# --- Sampling primitives ----------------------------------------------------

# Prints "<used_percent>,<available_mb>" for MONITOR_FS.
read_disk() {
    local result
    result=$(df -Pm "$MONITOR_FS" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print ($5 + 0) "," ($4 + 0); exit }')
    if [ -z "$result" ]; then
        result="0,0"
    fi
    echo "$result"
}

# Prints "<available_mb>,<swap_used_mb>".
read_mem() {
    local result
    result=$(awk '/^MemAvailable:/ { avail = $2 } /^SwapTotal:/ { stotal = $2 } /^SwapFree:/ { sfree = $2 } END { print int(avail / 1024) "," int((stotal - sfree) / 1024) }' /proc/meminfo 2>/dev/null)
    if [ -z "$result" ]; then
        result="0,0"
    fi
    echo "$result"
}

# Prints the largest RSS in MB among the processes that do the heavy lifting.
#
# /proc is read directly instead of calling ps(1): the osm2parquet image ships
# without procps, so a ps-based sampler reports 0 MB on every sample and the
# memory side of this log becomes silently useless - which is precisely the
# measurement needed to tell an out-of-memory kill from disk exhaustion.
read_peak_rss_mb() {
    local max_kb=0
    local proc_dir comm rss_kb

    for proc_dir in /proc/[0-9]*; do
        comm=$(cat "${proc_dir}/comm" 2>/dev/null) || continue
        case "$comm" in
            duckdb | osmium) ;;
            *) continue ;;
        esac

        rss_kb=$(awk '/^VmRSS:/ { print $2 + 0; exit }' "${proc_dir}/status" 2>/dev/null)
        if [ -n "$rss_kb" ] && [ "$rss_kb" -gt "$max_kb" ]; then
            max_kb="$rss_kb"
        fi
    done

    echo "$((max_kb / 1024))"
}

# Prints the size of a directory or file in MB, or 0 if it does not exist.
dir_size_mb() {
    local target="$1"
    local size=""
    if [ -e "$target" ]; then
        size=$(du -sm "$target" 2>/dev/null | awk 'NR == 1 { print $1 + 0; exit }')
    fi
    if [ -z "$size" ]; then
        size="0"
    fi
    echo "$size"
}

# --- Summary mode -----------------------------------------------------------

print_summary() {
    local csv_log="$1"

    if [ ! -f "$csv_log" ]; then
        echo "[WARN] No resource log found at ${csv_log}; skipping peak summary."
        return 0
    fi

    awk -F, '
        NR == 1 {
            columns = NF
            for (i = 8; i <= NF; i++) {
                label[i] = $i
                sub(/_mb$/, "", label[i])
            }
            next
        }
        {
            samples++
            if ($3 + 0 > peak_disk_used) {
                peak_disk_used = $3 + 0
            }
            if (min_disk_avail == "" || $4 + 0 < min_disk_avail) {
                min_disk_avail = $4 + 0
            }
            if (min_mem_avail == "" || $5 + 0 < min_mem_avail) {
                min_mem_avail = $5 + 0
            }
            if ($6 + 0 > peak_swap) {
                peak_swap = $6 + 0
            }
            if ($7 + 0 > peak_rss) {
                peak_rss = $7 + 0
            }
            for (i = 8; i <= columns; i++) {
                if ($i + 0 > peak_dir[i]) {
                    peak_dir[i] = $i + 0
                }
            }
            last_elapsed = $2 + 0
        }
        END {
            if (samples == 0) {
                print "[WARN] Resource log contains no samples."
                exit
            }
            print "[PEAK] ---- Resource peaks over " samples " samples / " (last_elapsed + 0) "s ----"
            print "[PEAK] Filesystem used (max)  : " (peak_disk_used + 0) "%"
            print "[PEAK] Filesystem free (min)  : " (min_disk_avail + 0) " MB"
            print "[PEAK] Memory available (min) : " (min_mem_avail + 0) " MB"
            print "[PEAK] Swap used (max)        : " (peak_swap + 0) " MB"
            print "[PEAK] Process RSS (max)      : " (peak_rss + 0) " MB"
            for (i = 8; i <= columns; i++) {
                print "[PEAK] Scratch peak " label[i] " : " (peak_dir[i] + 0) " MB"
            }
        }
    ' "$csv_log"
}

# --- Entry point ------------------------------------------------------------

if [ "$#" -lt 1 ]; then
    print_usage
    exit 1
fi

if [ "$1" = "--summary" ]; then
    if [ "$#" -lt 2 ]; then
        print_usage
        exit 1
    fi
    print_summary "$2"
    exit 0
fi

if [ "$#" -lt 2 ]; then
    print_usage
    exit 1
fi

CSV_LOG="$1"
INTERVAL="$2"
shift 2
WATCH_DIRS=("$@")

LOG_DIR=$(dirname "$CSV_LOG")
mkdir -p "$LOG_DIR"

HEADER="timestamp,elapsed_s,disk_used_pct,disk_avail_mb,mem_avail_mb,swap_used_mb,proc_peak_rss_mb"
if [ "${#WATCH_DIRS[@]}" -gt 0 ]; then
    for watch_dir in "${WATCH_DIRS[@]}"; do
        HEADER="${HEADER},${watch_dir}_mb"
    done
fi
echo "$HEADER" > "$CSV_LOG"

START_TS=$(date +%s)
trap 'exit 0' TERM INT

while true; do
    NOW_TS=$(date +%s)
    ELAPSED=$((NOW_TS - START_TS))
    STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    ROW="${STAMP},${ELAPSED},$(read_disk),$(read_mem),$(read_peak_rss_mb)"
    if [ "${#WATCH_DIRS[@]}" -gt 0 ]; then
        for watch_dir in "${WATCH_DIRS[@]}"; do
            ROW="${ROW},$(dir_size_mb "$watch_dir")"
        done
    fi
    echo "$ROW" >> "$CSV_LOG"

    # Echo to stdout as well (set MONITOR_ECHO=0 to suppress). The CSV is only
    # recoverable if the job survives to publish it as an artifact; a build
    # agent that dies from disk exhaustion never gets there, whereas Azure
    # DevOps retains the console lines it had already received.
    if [ "${MONITOR_ECHO:-1}" != "0" ]; then
        echo "[SAMPLE] $ROW"
    fi

    sleep "$INTERVAL"
done
