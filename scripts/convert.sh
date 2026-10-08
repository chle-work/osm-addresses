#!/usr/bin/env bash
# scripts/convert.sh — OSM PBF to GeoParquet conversion via DuckDB
# Usage: ./scripts/convert.sh <input.osm.pbf> <output.addresses.parquet> [country_code]
#
# Converts pre-filtered OSM PBF files into ZSTD-compressed GeoParquet files
# for addresses, roads, and entrances using DuckDB spatial extension.
#
# Resource behaviour:
#   Large extracts (US, Russia, Brazil) are bound by temporary disk space
#   rather than CPU, and both major consumers are unbounded by default:
#     * DuckDB spills the blocking ORDER BY ST_Hilbert() sort into
#       temp_directory. The spill is capped here via max_temp_directory_size so
#       that an oversized sort fails with a clear error instead of filling the
#       volume and taking the build agent offline without diagnostics.
#     * The GDAL OSM driver maintains a node cache in CPL_TMPDIR.
#   Both locations are pinned to one known scratch directory so that their
#   consumption is attributable and measurable by monitor_resources.sh.
#
# Environment overrides:
#   WORK_TMP_DIR          Parent directory for all scratch space
#   DUCKDB_TEMP_DIR       DuckDB spill directory
#   GDAL_TEMP_DIR         GDAL OSM driver scratch directory
#   DUCKDB_MEMORY_LIMIT   e.g. 4GB (default: DuckDB auto-detection)
#   DUCKDB_MAX_TEMP_SIZE  e.g. 20GB (default: 75% of free space on scratch volume)
#   DUCKDB_THREADS        e.g. 2 (default: DuckDB auto-detection)
#   OSM_COMPRESS_NODES    YES/NO (default: YES - trades CPU for scratch disk)
#   OSM_MAX_TMPFILE_SIZE  GDAL node cache RAM budget in MB (default: GDAL's own)
#   RESOURCE_LOG          CSV path; enables background resource sampling
#   RESOURCE_INTERVAL     Sampling interval in seconds (default: 10)

set -e

INPUT_PBF="$1"
OUTPUT_PARQUET="$2"
COUNTRY_CODE="${3:-${COUNTRY_CODE:-}}"

DIR_NAME="$(dirname "$OUTPUT_PARQUET")"
FILE_NAME="$(basename "$OUTPUT_PARQUET")"
BASE_NAME="${FILE_NAME%.addresses.parquet}"
BASE_NAME="${BASE_NAME%.roads.parquet}"
BASE_NAME="${BASE_NAME%.entrances.parquet}"
BASE_NAME="${BASE_NAME%.parquet}"

ADDRESSES_PARQUET="${DIR_NAME}/${BASE_NAME}.addresses.parquet"
ROADS_PARQUET="${DIR_NAME}/${BASE_NAME}.roads.parquet"
ENTRANCES_PARQUET="${DIR_NAME}/${BASE_NAME}.entrances.parquet"

# If COUNTRY_CODE is still empty, derive it from output filename (e.g. DE_germany.addresses.parquet -> DE)
if [ -z "$COUNTRY_CODE" ]; then
    COUNTRY_CODE="$(echo "$BASE_NAME" | cut -d_ -f1)"
fi
[ -z "$COUNTRY_CODE" ] && COUNTRY_CODE="unknown"

# --- Input validation (fail fast with diagnostic message) ---
if [ -z "$INPUT_PBF" ] || [ -z "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Missing required arguments."
    echo ""
    echo " Usage:  ./scripts/convert.sh <input.osm.pbf> <output.addresses.parquet> [country_code]"
    echo ""
    echo " Cause:  One or both CLI arguments were not supplied."
    echo " Fix:    Ensure the pipeline step passes INPUT_PBF and OUTPUT_PARQUET."
    echo "****************************************************************"
    exit 1
fi

if [ ! -f "$INPUT_PBF" ]; then
    echo "****************************************************************"
    echo " ERROR: Input PBF file not found: $INPUT_PBF"
    echo ""
    echo " Cause:  The input PBF file does not exist at the specified path."
    echo " Fix:    Verify that the upstream filter/download step succeeded."
    echo "****************************************************************"
    exit 1
fi

# --- Script and Config Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_ADDRESSES="${SCRIPT_DIR}/export_addresses.sql"
SQL_ROADS="${SCRIPT_DIR}/export_roads.sql"
SQL_ENTRANCES="${SCRIPT_DIR}/export_entrances.sql"
OSMCONF="${SCRIPT_DIR}/osmconf.ini"
MONITOR="${SCRIPT_DIR}/monitor_resources.sh"

for REQ_FILE in "$SQL_ADDRESSES" "$SQL_ROADS" "$SQL_ENTRANCES" "$OSMCONF"; do
    if [ ! -f "$REQ_FILE" ]; then
        echo "****************************************************************"
        echo " ERROR: Required file not found: $REQ_FILE"
        echo " Cause:  The scripts or config file is missing from scripts/."
        echo " Fix:    Ensure export_*.sql and osmconf.ini exist in scripts/."
        echo "****************************************************************"
        exit 1
    fi
done

# --- Scratch space configuration ---
WORK_TMP_DIR="${WORK_TMP_DIR:-${DIR_NAME}/.osm2parquet-tmp}"
DUCKDB_TEMP_DIR="${DUCKDB_TEMP_DIR:-${WORK_TMP_DIR}/duckdb}"
GDAL_TEMP_DIR="${GDAL_TEMP_DIR:-${WORK_TMP_DIR}/gdal}"
mkdir -p "$DUCKDB_TEMP_DIR" "$GDAL_TEMP_DIR"

# Pin the GDAL OSM driver node cache next to the DuckDB spill directory so that
# total scratch consumption is attributable. Node compression is on by default:
# it trades CPU for a markedly smaller node cache, and scratch disk - not CPU -
# is the scarce resource on hosted agents.
export CPL_TMPDIR="$GDAL_TEMP_DIR"
export OSM_COMPRESS_NODES="${OSM_COMPRESS_NODES:-YES}"
if [ -n "${OSM_MAX_TMPFILE_SIZE:-}" ]; then
    export OSM_MAX_TMPFILE_SIZE
fi

SCRATCH_AVAIL_MB="$(df -Pm "$DUCKDB_TEMP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 + 0; exit }')"
[ -z "$SCRATCH_AVAIL_MB" ] && SCRATCH_AVAIL_MB=0
SCRATCH_MOUNT="$(df -P "$DUCKDB_TEMP_DIR" 2>/dev/null | awk 'NR == 2 { print $6; exit }')"
[ -z "$SCRATCH_MOUNT" ] && SCRATCH_MOUNT="unknown"

# Default the spill cap to 75% of the currently free space on the scratch
# volume, leaving headroom for the GDAL node cache and the output Parquet.
if [ -z "${DUCKDB_MAX_TEMP_SIZE:-}" ] && [ "$SCRATCH_AVAIL_MB" -gt 0 ]; then
    DUCKDB_MAX_TEMP_SIZE="$((SCRATCH_AVAIL_MB * 75 / 100))MB"
fi

# Emits the SET statements prepended to every layer's SQL script.
build_duckdb_prelude() {
    echo "SET preserve_insertion_order = false;"
    echo "SET temp_directory = '${DUCKDB_TEMP_DIR}';"
    if [ -n "${DUCKDB_MAX_TEMP_SIZE:-}" ]; then
        echo "SET max_temp_directory_size = '${DUCKDB_MAX_TEMP_SIZE}';"
    fi
    if [ -n "${DUCKDB_MEMORY_LIMIT:-}" ]; then
        echo "SET memory_limit = '${DUCKDB_MEMORY_LIMIT}';"
    fi
    if [ -n "${DUCKDB_THREADS:-}" ]; then
        echo "SET threads = ${DUCKDB_THREADS};"
    fi
}

# Removes leftovers from a previously crashed run. DuckDB and GDAL clean up
# after themselves on a clean exit.
reset_scratch_dirs() {
    rm -rf "${DUCKDB_TEMP_DIR:?}"/* "${GDAL_TEMP_DIR:?}"/* 2>/dev/null || true
}

# --- Resource sampling ---
RESOURCE_LOG="${RESOURCE_LOG:-}"
RESOURCE_INTERVAL="${RESOURCE_INTERVAL:-10}"
MONITOR_PID=""

cleanup() {
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
        echo ""
        bash "$MONITOR" --summary "$RESOURCE_LOG" || true
    fi
}
trap cleanup EXIT

if [ -n "$RESOURCE_LOG" ]; then
    if [ -f "$MONITOR" ]; then
        # Sample the volume that actually holds the spill files rather than the
        # sampler's "/" default. In a container job "/" is the image's overlay
        # filesystem, while the scratch directory is a bind mount from the host;
        # only the latter is the volume that fills up and takes the agent
        # offline, so measuring "/" can describe the wrong device entirely.
        if [ -z "${MONITOR_FS:-}" ] && [ "$SCRATCH_MOUNT" != "unknown" ]; then
            MONITOR_FS="$SCRATCH_MOUNT"
        fi
        export MONITOR_FS="${MONITOR_FS:-/}"

        bash "$MONITOR" "$RESOURCE_LOG" "$RESOURCE_INTERVAL" "$DUCKDB_TEMP_DIR" "$GDAL_TEMP_DIR" "$DIR_NAME" &
        MONITOR_PID=$!
        echo "[INFO] Resource sampling enabled: $RESOURCE_LOG (every ${RESOURCE_INTERVAL}s, volume ${MONITOR_FS})"
    else
        echo "[WARN] RESOURCE_LOG is set but $MONITOR is missing; sampling disabled."
    fi
fi

# --- Execution ---
INPUT_MB="$(du -sm "$INPUT_PBF" | cut -f1)"

echo "[INFO] Input PBF     : $INPUT_PBF ($(du -sh "$INPUT_PBF" | cut -f1))"
echo "[INFO] Addresses Out : $ADDRESSES_PARQUET"
echo "[INFO] Roads Out     : $ROADS_PARQUET"
echo "[INFO] Entrances Out : $ENTRANCES_PARQUET"
echo "[INFO] Country Code  : $COUNTRY_CODE"
echo "[INFO] Scratch Dir   : $WORK_TMP_DIR on $SCRATCH_MOUNT (${SCRATCH_AVAIL_MB} MB free, input ${INPUT_MB} MB)"
echo "[INFO] DuckDB limits : memory=${DUCKDB_MEMORY_LIMIT:-auto} threads=${DUCKDB_THREADS:-auto} max_temp=${DUCKDB_MAX_TEMP_SIZE:-unbounded}"
echo "[INFO] GDAL cache    : CPL_TMPDIR=$CPL_TMPDIR OSM_COMPRESS_NODES=$OSM_COMPRESS_NODES"

# Provisional disk budget guard. The factors are deliberately coarse until the
# measured scratch-to-input ratio is known; their purpose is to turn a silent
# agent death into an actionable error message.
if [ "$INPUT_MB" -gt 0 ] && [ "$SCRATCH_AVAIL_MB" -gt 0 ]; then
    if [ "$SCRATCH_AVAIL_MB" -lt "$((INPUT_MB * 2))" ]; then
        echo "****************************************************************"
        echo " ERROR: Insufficient scratch space for conversion."
        echo ""
        echo " Input PBF    : ${INPUT_MB} MB"
        echo " Scratch free : ${SCRATCH_AVAIL_MB} MB on ${SCRATCH_MOUNT}"
        echo ""
        echo " Cause:  DuckDB spills the ORDER BY sort and GDAL caches OSM nodes"
        echo "         on this volume; both exceed the remaining free space."
        echo " Fix:    Free disk space on the agent, point WORK_TMP_DIR at a"
        echo "         larger volume, or process a smaller sub-region."
        echo "****************************************************************"
        exit 1
    fi
    if [ "$SCRATCH_AVAIL_MB" -lt "$((INPUT_MB * 6))" ]; then
        echo "[WARN] Scratch space is below 6x the input PBF size. Conversion of"
        echo "[WARN] large extracts may exhaust the volume; watch the peaks below."
    fi
fi

START_TIME=$(date +%s)
EXPORTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Reports what a finished export actually cost in scratch space.
#
# du(1) on the scratch directory is near-zero by the time an export returns and
# says nothing about the cost: the GDAL OSM node cache is unlinked while open,
# so it never appears in a directory listing, and it is released the instant the
# dataset closes. In the failing US run df(1) was the only reading that moved -
# the volume drained at roughly 3.9 MB/s while every watched directory stayed
# flat at 1 MB - so this line would have reported 1 MB for an export consuming
# gigabytes. The peak is therefore read back from the sampler's time series
# rather than measured after the fact.
report_layer_scratch() {
    local LAYER_NAME="$1"
    local SINCE_ISO="$2"
    local VOLUME_USED="$3"
    local LEFTOVER_MB
    LEFTOVER_MB=$(du -sm "$WORK_TMP_DIR" 2>/dev/null | cut -f1)

    if [ -z "$RESOURCE_LOG" ] || [ ! -f "$RESOURCE_LOG" ]; then
        echo "[INFO] Scratch after ${LAYER_NAME}: ${LEFTOVER_MB:-0} MB left on disk, peak unmeasured (sampling off); volume ${SCRATCH_MOUNT} now at ${VOLUME_USED}"
        return 0
    fi

    local PEAK_LINE
    PEAK_LINE=$(bash "$MONITOR" --peak-since "$RESOURCE_LOG" "$SINCE_ISO" 2>/dev/null) || PEAK_LINE="0 0 0"

    local PEAK_UNLINKED_MB MIN_AVAIL_MB PEAK_SAMPLES
    read -r PEAK_UNLINKED_MB MIN_AVAIL_MB PEAK_SAMPLES <<< "$PEAK_LINE"

    echo "[INFO] Scratch after ${LAYER_NAME}: ${LEFTOVER_MB:-0} MB left on disk, peak ${PEAK_UNLINKED_MB:-0} MB held unlinked over ${PEAK_SAMPLES:-0} samples; volume ${SCRATCH_MOUNT} now at ${VOLUME_USED} (min free ${MIN_AVAIL_MB:-0} MB)"
}

export_layer() {
    local SQL_TEMPLATE="$1"
    local TARGET_PARQUET="$2"
    local LAYER_NAME="$3"
    local LAYER_START
    LAYER_START=$(date +%s)
    local LAYER_START_ISO
    LAYER_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    reset_scratch_dirs

    echo "[INFO] Exporting ${LAYER_NAME} -> ${TARGET_PARQUET}..."
    local TMP_SQL
    TMP_SQL=$(mktemp /tmp/export_XXXXXX.sql)
    build_duckdb_prelude > "$TMP_SQL"
    sed -e "s|__INPUT_PBF__|${INPUT_PBF}|g" -e "s|__OUTPUT_PARQUET__|${TARGET_PARQUET}|g" -e "s|__COUNTRY_CODE__|${COUNTRY_CODE}|g" -e "s|__EXPORTED_AT__|${EXPORTED_AT}|g" -e "s|__OSMCONF__|${OSMCONF}|g" "$SQL_TEMPLATE" >> "$TMP_SQL"

    duckdb < "$TMP_SQL"
    rm -f "$TMP_SQL"

    if [ ! -f "$TARGET_PARQUET" ]; then
        echo "****************************************************************"
        echo " ERROR: Expected output file was not produced: $TARGET_PARQUET"
        echo " Layer:  ${LAYER_NAME}"
        echo " Cause:  DuckDB completed without error but produced no output."
        echo "****************************************************************"
        exit 1
    fi

    local LAYER_END
    LAYER_END=$(date +%s)
    local LAYER_ELAPSED=$((LAYER_END - LAYER_START))
    local FILE_SIZE
    FILE_SIZE=$(du -sh "$TARGET_PARQUET" | cut -f1)
    local VOLUME_USED
    VOLUME_USED=$(df -P "$DUCKDB_TEMP_DIR" 2>/dev/null | awk 'NR == 2 { print $5; exit }')
    echo "[OK] Exported ${LAYER_NAME}: ${TARGET_PARQUET} (${FILE_SIZE}) in ${LAYER_ELAPSED}s"
    report_layer_scratch "$LAYER_NAME" "$LAYER_START_ISO" "${VOLUME_USED:-unknown}"
}

# 1. Export address points & building polygons
export_layer "$SQL_ADDRESSES" "$ADDRESSES_PARQUET" "addresses"

# 2. Export drivable road centerlines
export_layer "$SQL_ROADS" "$ROADS_PARQUET" "roads"

# 3. Export entrance nodes & access gates
export_layer "$SQL_ENTRANCES" "$ENTRANCES_PARQUET" "entrances"

reset_scratch_dirs

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "[OK] Successfully converted all layers for ${BASE_NAME} in ${ELAPSED}s"
