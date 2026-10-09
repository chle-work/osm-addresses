#!/usr/bin/env python3
"""
Comprehensive validation script for osm-addresses GeoParquet datasets.

Performs quality, completeness, and regression checks across generated
addresses, roads, and entrances Parquet files:
  1. File Integrity & Size Check (> 0 bytes)
  2. Schema & Column Integrity Check (required columns present)
  3. Addressing Type Completeness Check (osm_type has both 'node' and 'way';
     detects silent loss of building ways)
  4. Road Truncation & Volume Check (osm_id not truncated, no NULL osm_id)
  5. Parquet Provenance & License Metadata Invariant (Rule 11)

Outputs human-readable diagnostic tables and native Azure DevOps annotations
(##vso[task.logissue type=warning/error]...).

Usage:
    python3 scripts/validate_parquet.py <path_or_prefix_or_dir> [--fail-on-error]
    python3 scripts/validate_parquet.py AT_austria.addresses.parquet AT_austria.roads.parquet AT_austria.entrances.parquet
"""

import argparse
import glob
import json
import os
import subprocess
import sys

REQUIRED_METADATA_KEYS = [
    "source",
    "origin",
    "dataset",
    "attribution",
    "attribution_url",
    "license",
    "license_url",
    "copyright",
    "schema",
    "schema_url",
    "compiler",
    "country_code",
    "exported_at",
]

ADDRESS_REQUIRED_COLUMNS = ["osm_id", "osm_type", "number", "street", "geometry"]
ROAD_REQUIRED_COLUMNS = ["osm_id", "osm_type", "highway", "geometry"]
ENTRANCE_REQUIRED_COLUMNS = ["osm_id", "osm_type", "geometry"]


def run_duckdb_query(sql):
    """Execute a SQL query using duckdb CLI or python duckdb module, returning parsed JSON."""
    try:
        import duckdb
        rel = duckdb.sql(sql)
        json_str = rel.fetch_arrow_table().to_pylist() if hasattr(rel, 'fetch_arrow_table') else None
        if json_str is not None:
            return json_str
    except Exception:
        pass

    # Fallback to CLI duckdb
    cmd = ["duckdb", "-light-mode", "-json", "-c", sql]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"DuckDB CLI query failed (code {res.returncode}): {res.stderr.strip()}")
    try:
        return json.loads(res.stdout) if res.stdout.strip() else []
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Failed to parse DuckDB JSON output: {res.stdout}") from exc


def get_parquet_columns(file_path):
    """Return list of column names in parquet file."""
    sql = f"DESCRIBE SELECT * FROM read_parquet('{file_path}');"
    rows = run_duckdb_query(sql)
    return [r["column_name"] for r in rows if "column_name" in r]


def get_parquet_metadata_keys(file_path):
    """Return list of metadata keys from parquet footer."""
    sql = f"SELECT key::VARCHAR AS k FROM parquet_kv_metadata('{file_path}');"
    rows = run_duckdb_query(sql)
    return [r["k"] for r in rows if "k" in r]


def validate_addresses_file(file_path):
    """Validate addresses.parquet file."""
    issues = []
    stats = {}
    if not os.path.exists(file_path) or os.path.getsize(file_path) == 0:
        return {"file": file_path, "status": "ERROR", "issues": ["File missing or 0 bytes"], "stats": {}}

    try:
        cols = get_parquet_columns(file_path)
        stats["columns"] = cols
        for req_col in ADDRESS_REQUIRED_COLUMNS:
            if req_col not in cols:
                issues.append(f"Missing required column '{req_col}'")

        meta_keys = get_parquet_metadata_keys(file_path)
        missing_meta = [k for k in REQUIRED_METADATA_KEYS if k not in meta_keys]
        if missing_meta:
            issues.append(f"Missing KV_METADATA keys: {missing_meta}")

        sql = f"""
        SELECT
            count(*) AS total_rows,
            count(*) FILTER (WHERE osm_type = 'way') AS way_count,
            count(*) FILTER (WHERE osm_type = 'node') AS node_count,
            count(*) FILTER (WHERE osm_type = 'relation') AS relation_count,
            count(*) FILTER (WHERE osm_id IS NULL) AS null_id_count,
            count(*) FILTER (WHERE number IS NULL) AS null_number_count
        FROM read_parquet('{file_path}');
        """
        rows = run_duckdb_query(sql)
        if rows:
            r = rows[0]
            stats.update(r)
            total = r.get("total_rows", 0)
            ways = r.get("way_count", 0)
            nodes = r.get("node_count", 0)
            null_ids = r.get("null_id_count", 0)

            if total == 0:
                issues.append("Dataset is empty (0 address rows)")
            if null_ids > 0:
                issues.append(f"Found {null_ids} addresses with NULL osm_id")

            # Regression check: If total addresses > 500 but way_count == 0,
            # this is a strong signature of the building-ways missing bug (Rule 12).
            if total > 500 and ways == 0:
                issues.append(
                    f"POTENTIAL REGRESSION: 0 building ways found among {total:,} addresses "
                    f"({nodes:,} nodes). In OSM, building ways should represent a significant portion."
                )

    except Exception as exc:
        issues.append(f"Query error: {exc}")

    status = "ERROR" if issues else "OK"
    return {"file": file_path, "status": status, "issues": issues, "stats": stats}


def validate_roads_file(file_path):
    """Validate roads.parquet file."""
    issues = []
    stats = {}
    if not os.path.exists(file_path) or os.path.getsize(file_path) == 0:
        return {"file": file_path, "status": "ERROR", "issues": ["File missing or 0 bytes"], "stats": {}}

    try:
        cols = get_parquet_columns(file_path)
        stats["columns"] = cols
        for req_col in ROAD_REQUIRED_COLUMNS:
            if req_col not in cols:
                issues.append(f"Missing required column '{req_col}'")

        meta_keys = get_parquet_metadata_keys(file_path)
        missing_meta = [k for k in REQUIRED_METADATA_KEYS if k not in meta_keys]
        if missing_meta:
            issues.append(f"Missing KV_METADATA keys: {missing_meta}")

        sql = f"""
        SELECT
            count(*) AS total_rows,
            count(*) FILTER (WHERE osm_id IS NULL) AS null_id_count,
            min(osm_id) AS min_osm_id,
            max(osm_id) AS max_osm_id,
            count(*) FILTER (WHERE name IS NOT NULL) AS named_roads_count
        FROM read_parquet('{file_path}');
        """
        rows = run_duckdb_query(sql)
        if rows:
            r = rows[0]
            stats.update(r)
            total = r.get("total_rows", 0)
            max_id = r.get("max_osm_id", 0)
            null_ids = r.get("null_id_count", 0)

            if total == 0:
                issues.append("Dataset is empty (0 roads)")
            if null_ids > 0:
                issues.append(f"Found {null_ids} roads with NULL osm_id")

            # Regression check: If roads cut off at max_osm_id < 10_000_000 on a substantial extract,
            # it indicates GDAL unconsumed feature buffering stream truncation.
            if total > 50000 and max_id and max_id < 10000000:
                issues.append(
                    f"POTENTIAL REGRESSION: Road IDs appear truncated at max osm_id={max_id} "
                    f"(expected contemporary IDs exceeding 100,000,000+). Check INTERLEAVED_READING=YES."
                )

    except Exception as exc:
        issues.append(f"Query error: {exc}")

    status = "ERROR" if issues else "OK"
    return {"file": file_path, "status": status, "issues": issues, "stats": stats}


def validate_entrances_file(file_path):
    """Validate entrances.parquet file."""
    issues = []
    stats = {}
    if not os.path.exists(file_path) or os.path.getsize(file_path) == 0:
        return {"file": file_path, "status": "ERROR", "issues": ["File missing or 0 bytes"], "stats": {}}

    try:
        cols = get_parquet_columns(file_path)
        stats["columns"] = cols
        for req_col in ENTRANCE_REQUIRED_COLUMNS:
            if req_col not in cols:
                issues.append(f"Missing required column '{req_col}'")

        meta_keys = get_parquet_metadata_keys(file_path)
        missing_meta = [k for k in REQUIRED_METADATA_KEYS if k not in meta_keys]
        if missing_meta:
            issues.append(f"Missing KV_METADATA keys: {missing_meta}")

        sql = f"""
        SELECT
            count(*) AS total_rows,
            count(*) FILTER (WHERE osm_id IS NULL) AS null_id_count,
            count(*) FILTER (WHERE entrance IS NOT NULL) AS entrance_tag_count,
            count(*) FILTER (WHERE barrier IS NOT NULL) AS barrier_tag_count
        FROM read_parquet('{file_path}');
        """
        rows = run_duckdb_query(sql)
        if rows:
            r = rows[0]
            stats.update(r)
            null_ids = r.get("null_id_count", 0)
            if null_ids > 0:
                issues.append(f"Found {null_ids} entrances with NULL osm_id")

    except Exception as exc:
        issues.append(f"Query error: {exc}")

    status = "ERROR" if issues else "OK"
    return {"file": file_path, "status": status, "issues": issues, "stats": stats}


def main():
    parser = argparse.ArgumentParser(description="Validate osm-addresses GeoParquet datasets.")
    parser.add_argument("targets", nargs="+", help="Parquet files, directories, or prefixes to validate")
    parser.add_argument("--fail-on-error", action="store_true", help="Exit with code 1 if any validation error occurs")
    args = parser.parse_args()

    files_to_check = []
    for target in args.targets:
        if os.path.isdir(target):
            files_to_check.extend(glob.glob(os.path.join(target, "**", "*.parquet"), recursive=True))
        elif os.path.isfile(target):
            files_to_check.append(target)
        else:
            matches = glob.glob(f"{target}*.parquet")
            if matches:
                files_to_check.extend(matches)
            else:
                print(f"[WARN] Target not found: {target}", file=sys.stderr)

    if not files_to_check:
        print("[ERROR] No Parquet files found to validate.", file=sys.stderr)
        sys.exit(1 if args.fail_on_error else 0)

    results = []
    for fp in sorted(set(files_to_check)):
        basename = os.path.basename(fp)
        if "addresses.parquet" in basename:
            results.append(validate_addresses_file(fp))
        elif "roads.parquet" in basename:
            results.append(validate_roads_file(fp))
        elif "entrances.parquet" in basename:
            results.append(validate_entrances_file(fp))
        else:
            # Generic parquet check
            results.append({"file": fp, "status": "SKIPPED", "issues": ["Unknown layer type"], "stats": {}})

    print("\n" + "=" * 80)
    print(" OSM-ADDRESSES PARQUET VALIDATION REPORT")
    print("=" * 80)

    has_errors = False
    for res in results:
        fp = res["file"]
        status = res["status"]
        issues = res["issues"]
        stats = res["stats"]

        status_tag = f"[{status}]"
        print(f"\n{status_tag:<10} {fp}")
        if stats:
            stat_summary = ", ".join(f"{k}={v}" for k, v in stats.items() if k != "columns")
            print(f"           Stats: {stat_summary}")
        if issues:
            for issue in issues:
                print(f"           - {issue}")
                if "POTENTIAL REGRESSION" in issue:
                    print(f"##vso[task.logissue type=error]Regression in {fp}: {issue}")
                elif status == "ERROR":
                    print(f"##vso[task.logissue type=error]Validation failure in {fp}: {issue}")
                else:
                    print(f"##vso[task.logissue type=warning]Validation notice in {fp}: {issue}")
            if status == "ERROR":
                has_errors = True

    print("\n" + "=" * 80)
    total_files = len(results)
    err_files = sum(1 for r in results if r["status"] == "ERROR")
    print(f"Summary: {total_files} file(s) checked, {err_files} error(s).")
    print("=" * 80 + "\n")

    if has_errors and args.fail_on_error:
        sys.exit(1)


if __name__ == "__main__":
    main()
