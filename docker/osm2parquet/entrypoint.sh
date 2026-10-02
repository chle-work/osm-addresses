#!/bin/bash
# entrypoint.sh — OSM PBF to GeoParquet conversion via DuckDB
# Usage: /app/entrypoint.sh <input.osm.pbf> <output.addresses.parquet>
#
# Invoked directly by the Azure DevOps agent when the job runs inside the
# osm2parquet container (Container-Job-Pattern, no docker run needed).

set -e

INPUT_PBF="$1"
OUTPUT_PARQUET="$2"
COUNTRY_CODE="${3:-${COUNTRY_CODE:-}}"

# If COUNTRY_CODE is still empty, derive it from output filename (e.g. DE_germany.addresses.parquet -> DE)
if [ -z "$COUNTRY_CODE" ]; then
    BASE_NAME="$(basename "$OUTPUT_PARQUET")"
    COUNTRY_CODE="$(echo "$BASE_NAME" | cut -d_ -f1)"
fi
[ -z "$COUNTRY_CODE" ] && COUNTRY_CODE="unknown"

# --- Input validation (fail fast with diagnostic message) ---
if [ -z "$INPUT_PBF" ] || [ -z "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Missing required arguments."
    echo ""
    echo " Usage:  /app/entrypoint.sh <input.osm.pbf> <output.addresses.parquet> [country_code]"
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
    echo " Cause:  The DownloadPipelineArtifact step may have failed,"
    echo "         or the path passed as argument is incorrect."
    echo " Fix:    Verify that the osm-download pipeline (definition 3)"
    echo "         has produced an artifact for this region and that the"
    echo "         itemPattern in DownloadPipelineArtifact matches."
    echo "****************************************************************"
    exit 1
fi

# --- Execution ---
echo "[INFO] Input       : $INPUT_PBF ($(du -sh "$INPUT_PBF" | cut -f1))"
echo "[INFO] Output      : $OUTPUT_PARQUET"
echo "[INFO] Country Code: $COUNTRY_CODE"
START_TIME=$(date +%s)
EXPORTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Script and Config Resolution ---
# Scripts and config are resolved relative to entrypoint.sh from the mounted workspace
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_TEMPLATE="${SCRIPT_DIR}/export_addresses.sql"
OSMCONF="${SCRIPT_DIR}/osmconf.ini"

if [ ! -f "$SQL_TEMPLATE" ]; then
    echo "****************************************************************"
    echo " ERROR: SQL template not found: $SQL_TEMPLATE"
    echo " Cause:  The workspace containing export_addresses.sql is not mounted."
    echo " Fix:    Ensure the repository workspace is bind-mounted into the container."
    echo "****************************************************************"
    exit 1
fi

if [ ! -f "$OSMCONF" ]; then
    echo "****************************************************************"
    echo " ERROR: OSM config not found: $OSMCONF"
    echo " Cause:  The workspace containing osmconf.ini is not mounted."
    echo " Fix:    Ensure the repository workspace is bind-mounted into the container."
    echo "****************************************************************"
    exit 1
fi

# Substitute placeholder tokens with actual paths, then pipe to duckdb stdin.
# getvariable() cannot be used in COPY TO (requires string literal) — sed
# substitution embeds the paths as literals before DuckDB sees the SQL.
TMP_SQL=$(mktemp /tmp/export_XXXXXX.sql)
sed \
  -e "s|__INPUT_PBF__|${INPUT_PBF}|g" \
  -e "s|__OUTPUT_PARQUET__|${OUTPUT_PARQUET}|g" \
  -e "s|__COUNTRY_CODE__|${COUNTRY_CODE}|g" \
  -e "s|__EXPORTED_AT__|${EXPORTED_AT}|g" \
  -e "s|/app/osmconf.ini|${OSMCONF}|g" \
  "$SQL_TEMPLATE" > "$TMP_SQL"

duckdb < "$TMP_SQL"
rm -f "$TMP_SQL"


END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ ! -f "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Expected output file was not produced: $OUTPUT_PARQUET"
    echo ""
    echo " Cause:  DuckDB completed without error but produced no output."
    echo "         The input PBF may contain no address-tagged features."
    echo " Fix:    Inspect the region's OSM data for addr:housenumber"
    echo "         and addr:street/addr:place tags."
    echo "****************************************************************"
    exit 1
fi

FILE_SIZE=$(du -sh "$OUTPUT_PARQUET" | cut -f1)
echo "[OK] Successfully exported GeoParquet: $OUTPUT_PARQUET ($FILE_SIZE) in ${ELAPSED}s"
