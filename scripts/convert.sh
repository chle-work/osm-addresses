#!/usr/bin/env bash
# scripts/convert.sh — OSM PBF to GeoParquet conversion via DuckDB
# Usage: ./scripts/convert.sh <input.osm.pbf> <output.addresses.parquet> [country_code]
#
# Converts pre-filtered OSM PBF files into ZSTD-compressed GeoParquet files
# for addresses, roads, and entrances using DuckDB spatial extension.

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

# --- Execution ---
echo "[INFO] Input PBF     : $INPUT_PBF ($(du -sh "$INPUT_PBF" | cut -f1))"
echo "[INFO] Addresses Out : $ADDRESSES_PARQUET"
echo "[INFO] Roads Out     : $ROADS_PARQUET"
echo "[INFO] Entrances Out : $ENTRANCES_PARQUET"
echo "[INFO] Country Code  : $COUNTRY_CODE"
START_TIME=$(date +%s)
EXPORTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Script and Config Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_ADDRESSES="${SCRIPT_DIR}/export_addresses.sql"
SQL_ROADS="${SCRIPT_DIR}/export_roads.sql"
SQL_ENTRANCES="${SCRIPT_DIR}/export_entrances.sql"
OSMCONF="${SCRIPT_DIR}/osmconf.ini"

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

export_layer() {
    local SQL_TEMPLATE="$1"
    local TARGET_PARQUET="$2"
    local LAYER_NAME="$3"
    local LAYER_START
    LAYER_START=$(date +%s)

    echo "[INFO] Exporting ${LAYER_NAME} -> ${TARGET_PARQUET}..."
    local TMP_SQL
    TMP_SQL=$(mktemp /tmp/export_XXXXXX.sql)
    sed \
      -e "s|__INPUT_PBF__|${INPUT_PBF}|g" \
      -e "s|__OUTPUT_PARQUET__|${TARGET_PARQUET}|g" \
      -e "s|__COUNTRY_CODE__|${COUNTRY_CODE}|g" \
      -e "s|__EXPORTED_AT__|${EXPORTED_AT}|g" \
      -e "s|__OSMCONF__|${OSMCONF}|g" \
      "$SQL_TEMPLATE" > "$TMP_SQL"

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
    echo "[OK] Exported ${LAYER_NAME}: ${TARGET_PARQUET} (${FILE_SIZE}) in ${LAYER_ELAPSED}s"
}

# 1. Export address points & building polygons
export_layer "$SQL_ADDRESSES" "$ADDRESSES_PARQUET" "addresses"

# 2. Export drivable road centerlines
export_layer "$SQL_ROADS" "$ROADS_PARQUET" "roads"

# 3. Export entrance nodes & access gates
export_layer "$SQL_ENTRANCES" "$ENTRANCES_PARQUET" "entrances"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "[OK] Successfully converted all layers for ${BASE_NAME} in ${ELAPSED}s"
