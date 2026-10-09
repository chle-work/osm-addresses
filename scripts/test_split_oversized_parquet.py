#!/usr/bin/env python3
"""Unit tests for split_oversized_parquet.py."""

import unittest
from unittest.mock import patch

from split_oversized_parquet import split_file


class TestSplitOversizedParquet(unittest.TestCase):

    def test_split_file_uses_hash_buckets_and_preserves_metadata(self):
        source_file = "/work/DE_germany.roads.parquet"
        part_files = [
            "/work/DE_germany.roads.part1.parquet",
            "/work/DE_germany.roads.part2.parquet",
            "/work/DE_germany.roads.part3.parquet",
        ]
        source_size = int(2.5 * 1024 * 1024)

        def getsize(path):
            if path == source_file:
                return source_size
            self.assertIn(path, part_files)
            return 512 * 1024

        with patch("split_oversized_parquet.os.path.getsize", side_effect=getsize), patch(
            "split_oversized_parquet.subprocess.check_output",
            side_effect=[
                b'[{"null_id_count": 0}]',
                b'[{"key": "source", "value": "OpenStreetMap"}]',
            ],
        ) as check_output, patch(
            "split_oversized_parquet.subprocess.check_call"
        ) as check_call, patch("split_oversized_parquet.os.remove") as remove:
            created_parts = split_file(source_file, max_size_mb=1)

        self.assertEqual(created_parts, part_files)
        self.assertEqual(check_output.call_count, 2)
        self.assertIn("WHERE osm_id IS NULL", check_output.call_args_list[0].args[0][3])
        self.assertNotIn("-dark-mode", check_output.call_args_list[0].args[0])
        self.assertIn("parquet_kv_metadata", check_output.call_args_list[1].args[0][3])
        self.assertEqual(check_call.call_count, 3)

        for part_number, call in enumerate(check_call.call_args_list, start=1):
            command = call.args[0]
            self.assertEqual(command[:2], ["duckdb", "-c"])
            self.assertNotIn("-dark-mode", command)
            sql = command[2]
            self.assertNotIn("ntile(", sql)
            self.assertIn("hash(osm_type, osm_id) % 3", sql)
            self.assertIn(f"= {part_number - 1}", sql)
            self.assertIn(f"TO '{part_files[part_number - 1]}'", sql)
            self.assertIn("COMPRESSION 'ZSTD'", sql)
            self.assertIn("KV_METADATA {'source': 'OpenStreetMap'}", sql)

        remove.assert_called_once_with(source_file)

    def test_split_file_rejects_null_osm_ids_without_writing_or_deleting(self):
        source_file = "/work/DE_germany.roads.parquet"
        source_size = int(2.5 * 1024 * 1024)

        with patch(
            "split_oversized_parquet.os.path.getsize",
            return_value=source_size,
        ), patch(
            "split_oversized_parquet.subprocess.check_output",
            return_value=b'[{"null_id_count": 1}]',
        ), patch("split_oversized_parquet.subprocess.check_call") as check_call, patch(
            "split_oversized_parquet.os.remove"
        ) as remove:
            with self.assertRaisesRegex(ValueError, r"1 row\(s\) with NULL osm_id"):
                split_file(source_file, max_size_mb=1)

        check_call.assert_not_called()
        remove.assert_not_called()


if __name__ == "__main__":
    unittest.main()
