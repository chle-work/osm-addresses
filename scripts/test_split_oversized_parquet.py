#!/usr/bin/env python3
"""Unit tests for split_oversized_parquet.py."""

import unittest
from unittest.mock import patch

from split_oversized_parquet import split_file


class TestSplitOversizedParquet(unittest.TestCase):

    def test_split_file_uses_non_interactive_duckdb_commands_and_preserves_metadata(self):
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
            return_value=b'[{"key": "source", "value": "OpenStreetMap"}]',
        ) as check_output, patch(
            "split_oversized_parquet.subprocess.check_call"
        ) as check_call, patch("split_oversized_parquet.os.remove") as remove:
            created_parts = split_file(source_file, max_size_mb=1)

        self.assertEqual(created_parts, part_files)
        check_output.assert_called_once_with(
            [
                "duckdb",
                "-json",
                "-c",
                'SELECT key, value FROM parquet_kv_metadata("/work/DE_germany.roads.parquet")',
            ],
            stderr=unittest.mock.ANY,
        )
        self.assertNotIn("-dark-mode", check_output.call_args.args[0])
        self.assertEqual(check_call.call_count, 3)

        for part_number, call in enumerate(check_call.call_args_list, start=1):
            command = call.args[0]
            self.assertEqual(command[:2], ["duckdb", "-c"])
            self.assertNotIn("-dark-mode", command)
            sql = command[2]
            self.assertIn("ntile(3)", sql)
            self.assertIn(f"WHERE _part = {part_number}", sql)
            self.assertIn(f"TO '{part_files[part_number - 1]}'", sql)
            self.assertIn("COMPRESSION 'ZSTD'", sql)
            self.assertIn("KV_METADATA {'source': 'OpenStreetMap'}", sql)

        remove.assert_called_once_with(source_file)


if __name__ == "__main__":
    unittest.main()
