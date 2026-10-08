#!/usr/bin/env bash
# scripts/monitor_resources.sh — resource sampler for PBF -> GeoParquet conversions
#
# Usage:
#   ./scripts/monitor_resources.sh <csv_log> <interval_seconds> [watch_dir ...]
#   ./scripts/monitor_resources.sh --summary <csv_log>
#   ./scripts/monitor_resources.sh --peak-since <csv_log> <iso_timestamp>
#
# Sampling mode appends one CSV row per interval describing filesystem usage,
# available memory, swap usage, the largest resident set size among the
# conversion processes, the scratch space held in unlinked open files, and the
# size of each watched directory. Summary mode prints the peak values recorded
# in an existing CSV log. Peak-since mode prints the peaks for a single export
# phase, so the caller can report what that phase actually cost.
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
    echo "       monitor_resources.sh --peak-since <csv_log> <iso_timestamp>"
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

# Prints the PIDs of the processes that do the heavy lifting, one per line.
#
# /proc is read directly instead of calling ps(1) or pgrep(1): the osm2parquet
# image ships without procps, and an external-tool-based sampler fails silently
# there, reporting zero on every sample.
conversion_pids() {
    local proc_dir comm

    for proc_dir in /proc/[0-9]*; do
        comm=$(cat "${proc_dir}/comm" 2>/dev/null) || continue
        case "$comm" in
            duckdb | osmium) echo "${proc_dir#/proc/}" ;;
            *) continue ;;
        esac
    done
}

# Prints the largest RSS in MB among the conversion processes.
#
# This is precisely the measurement needed to tell an out-of-memory kill from
# disk exhaustion, so it must not be allowed to degrade to a constant zero.
read_peak_rss_mb() {
    local max_kb=0
    local pid rss_kb

    for pid in $(conversion_pids); do
        rss_kb=$(awk '/^VmRSS:/ { print $2 + 0; exit }' "/proc/${pid}/status" 2>/dev/null)
        if [ -n "$rss_kb" ] && [ "$rss_kb" -gt "$max_kb" ]; then
            max_kb="$rss_kb"
        fi
    done

    echo "$((max_kb / 1024))"
}

# Prints the total size in MB of the files that the conversion processes still
# hold open after those files have been unlinked.
#
# The GDAL OSM driver creates its node cache as CPL_TMPDIR/osm_tmp_nodes_<pid>_<n>
# and unlinks it immediately. The blocks stay allocated for the lifetime of the
# descriptor while no directory entry remains, so du(1) reports an empty scratch
# directory no matter which directory it is pointed at. In the failing US run
# df(1) was the only reading that moved: the volume drained at roughly 3.9 MB/s
# across the sampled window while every watched directory stayed flat at 1 MB.
# Reading the open descriptors is the only way to attribute that consumption,
# and the space is released the instant the dataset closes, so it has to be
# caught while the export is still running.
#
# Attributing that drain to the GDAL node cache specifically is still a
# hypothesis; this column exists to settle it, not because it is settled.
#
# Whatever the consumer turns out to be, this space is outside DuckDB's
# max_temp_directory_size accounting, which covers nothing but DuckDB's own
# spill, so no other mechanism bounds, reports or aborts on it.
read_unlinked_scratch_mb() {
    local total_bytes=0
    local pid fd target size

    for pid in $(conversion_pids); do
        for fd in "/proc/${pid}"/fd/*; do
            target=$(readlink "$fd" 2>/dev/null) || continue
            case "$target" in
                *"(deleted)") ;;
                *) continue ;;
            esac

            # The descriptor is followed, which still resolves for an inode
            # whose last directory entry is already gone.
            size=$(stat -L -c %s "$fd" 2>/dev/null) || continue
            if [ -n "$size" ]; then
                total_bytes=$((total_bytes + size))
            fi
        done
    done

    echo "$((total_bytes / 1048576))"
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

# --- Reporting modes --------------------------------------------------------
#
# Column 8 holds the unlinked scratch total; the watched directories start at
# column 9. The number of trailing columns varies with the number of watch
# directories passed at sampling time, so the header is the only reliable guide
# when reading a log back.

print_summary() {
    local csv_log="$1"

    if [ ! -f "$csv_log" ]; then
        echo "[WARN] No resource log found at ${csv_log}; skipping peak summary."
        return 0
    fi

    awk -F, '
        NR == 1 {
            columns = NF
            for (i = 9; i <= NF; i++) {
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
            if ($8 + 0 > peak_unlinked) {
                peak_unlinked = $8 + 0
            }
            for (i = 9; i <= columns; i++) {
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
            print "[PEAK] Unlinked scratch (max) : " (peak_unlinked + 0) " MB"
            for (i = 9; i <= columns; i++) {
                print "[PEAK] Scratch peak " label[i] " : " (peak_dir[i] + 0) " MB"
            }
        }
    ' "$csv_log"
}

# Prints "<peak_unlinked_mb> <min_disk_avail_mb> <samples>" across the samples
# taken at or after the given timestamp, for attributing cost to one export.
#
# Timestamps are written in a fixed-width UTC format, so comparing column 1
# lexicographically is a correct chronological filter and needs no date parsing.
print_peak_since() {
    local csv_log="$1"
    local since="$2"

    if [ ! -f "$csv_log" ]; then
        echo "0 0 0"
        return 0
    fi

    awk -F, -v since="$since" '
        NR == 1 { next }
        $1 < since { next }
        {
            samples++
            if ($8 + 0 > peak_unlinked) {
                peak_unlinked = $8 + 0
            }
            if (min_disk_avail == "" || $4 + 0 < min_disk_avail) {
                min_disk_avail = $4 + 0
            }
        }
        END { print (peak_unlinked + 0) " " (min_disk_avail + 0) " " (samples + 0) }
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

if [ "$1" = "--peak-since" ]; then
    if [ "$#" -lt 3 ]; then
        print_usage
        exit 1
    fi
    print_peak_since "$2" "$3"
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

HEADER="timestamp,elapsed_s,disk_used_pct,disk_avail_mb,mem_avail_mb,swap_used_mb,proc_peak_rss_mb,unlinked_scratch_mb"
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

    ROW="${STAMP},${ELAPSED},$(read_disk),$(read_mem),$(read_peak_rss_mb),$(read_unlinked_scratch_mb)"
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
