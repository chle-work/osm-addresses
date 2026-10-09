#!/usr/bin/env python3
"""
scripts/split_oversized_parquet.py

Splits any GeoParquet files larger than MAX_SIZE_MB (default 1800 MB, to stay
safely under the GitHub Release 2.0 GiB limit) into multiple valid GeoParquet
parts (.part1.parquet, .part2.parquet, ...) using DuckDB.

Preserves ZSTD compression and KV_METADATA footer tags.
"""

import argparse
import glob
import json
import math
import os
import subprocess
import sys

MAX_SIZE_MB_DEFAULT = 1800


def run_duckdb_json_query(sql):
    """Run a DuckDB SQL query and return JSON rows."""
    output = subprocess.check_output(
        ["duckdb", "-json", "-c", sql],
        stderr=subprocess.DEVNULL,
    ).decode("utf-8")
    return json.loads(output) if output.strip() else []


def get_kv_metadata(file_path):
    """Extract KV_METADATA from a parquet file using DuckDB."""
    try:
        rows = run_duckdb_json_query(
            f'SELECT key, value FROM parquet_kv_metadata("{file_path}")'
        )
        metadata = {}
        for row in rows:
            key = row.get("key")
            value = row.get("value")
            if key is not None and value is not None:
                metadata[key] = value
        return metadata
    except Exception as error:
        print(f"[WARN] Could not extract KV_METADATA from {file_path}: {error}", file=sys.stderr)
        return {}


def require_non_null_osm_ids(file_path):
    """Reject files whose rows cannot be deterministically hash partitioned."""
    rows = run_duckdb_json_query(
        f"SELECT count(*) FILTER (WHERE osm_id IS NULL) AS null_id_count "
        f"FROM read_parquet('{file_path}')"
    )
    null_id_count = rows[0]["null_id_count"] if rows else 0
    if null_id_count:
        raise ValueError(
            f"Cannot partition {file_path}: found {null_id_count} row(s) with NULL osm_id"
        )


def split_file(file_path, max_size_mb):
    """Split a single file into deterministic hash buckets if it exceeds max_size_mb."""
    size_bytes = os.path.getsize(file_path)
    size_mb = size_bytes / (1024 * 1024)
    if size_mb <= max_size_mb:
        return []

    num_parts = math.ceil(size_mb / max_size_mb)
    print(f"[INFO] File {file_path} is {size_mb:.1f} MB (exceeds limit {max_size_mb} MB).")
    print(f"[INFO] Partitioning into {num_parts} deterministic hash buckets using DuckDB...")

    dir_name = os.path.dirname(file_path)
    base_name = os.path.basename(file_path)
    stem = base_name[:-len(".parquet")]

    require_non_null_osm_ids(file_path)
    kv_dict = get_kv_metadata(file_path)
    kv_items = [f"{repr(str(key))}: {repr(str(value))}" for key, value in kv_dict.items()]
    kv_clause = (", KV_METADATA {" + ", ".join(kv_items) + "}") if kv_items else ""

    created_parts = []
    for part in range(1, num_parts + 1):
        part_file = os.path.join(dir_name, f"{stem}.part{part}.parquet")
        bucket = part - 1
        sql = f"""COPY (
            SELECT *
            FROM read_parquet('{file_path}')
            WHERE hash(osm_type, osm_id) % {num_parts} = {bucket}
        ) TO '{part_file}' (FORMAT PARQUET, COMPRESSION 'ZSTD'{kv_clause});"""

        print(f"[INFO] Generating {part_file} (part {part}/{num_parts})...")
        subprocess.check_call(["duckdb", "-c", sql])
        part_size_mb = os.path.getsize(part_file) / (1024 * 1024)
        print(f"[OK] Created {part_file} ({part_size_mb:.1f} MB)")
        created_parts.append(part_file)

    os.remove(file_path)
    print(f"[OK] Removed original oversized file: {file_path}")
    return created_parts


def main():
    parser = argparse.ArgumentParser(description="Split Parquet files > 2 GiB for GitHub Release")
    parser.add_argument("directory", help="Directory containing .parquet files")
    parser.add_argument(
        "--max-size-mb",
        type=float,
        default=MAX_SIZE_MB_DEFAULT,
        help=f"Maximum allowed size in MB (default: {MAX_SIZE_MB_DEFAULT})",
    )
    args = parser.parse_args()

    # Find all top-level parquet files (avoid processing already split parts)
    parquet_files = sorted(glob.glob(os.path.join(args.directory, "*.parquet")))
    split_count = 0
    for parquet_file in parquet_files:
        if ".part" in os.path.basename(parquet_file):
            continue
        parts = split_file(parquet_file, args.max_size_mb)
        if parts:
            split_count += 1

    if split_count == 0:
        print(f"[INFO] All Parquet files in {args.directory} are within the {args.max_size_mb} MB limit.")
    else:
        print(f"[INFO] Successfully partitioned {split_count} oversized Parquet file(s).")


if __name__ == "__main__":
    main()
