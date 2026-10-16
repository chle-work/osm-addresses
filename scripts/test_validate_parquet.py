#!/usr/bin/env python3
"""
Unit tests for validate_parquet.py.
"""

import os
import unittest

from unittest.mock import patch

from validate_parquet import (
    validate_addresses_file,
    validate_roads_file,
    validate_entrances_file,
    validate_waterways_file,
    WATERWAY_REQUIRED_COLUMNS,
    REQUIRED_METADATA_KEYS,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AT_DIR = os.path.join(REPO_ROOT, "osm-parquet-AT-austria")
AT_ADDRESSES = os.path.join(AT_DIR, "AT_austria.addresses.parquet")
AT_ROADS = os.path.join(AT_DIR, "AT_austria.roads.parquet")
AT_ENTRANCES = os.path.join(AT_DIR, "AT_austria.entrances.parquet")
AT_WATERWAYS = os.path.join(AT_DIR, "AT_austria.waterways.parquet")


class TestValidateParquet(unittest.TestCase):

    def test_missing_file_reports_error(self):
        res = validate_addresses_file("nonexistent.parquet")
        self.assertEqual(res["status"], "ERROR")
        self.assertIn("File missing or 0 bytes", res["issues"])

        res_waterways = validate_waterways_file("nonexistent_waterways.parquet")
        self.assertEqual(res_waterways["status"], "ERROR")
        self.assertIn("File missing or 0 bytes", res_waterways["issues"])

    @patch("validate_parquet.get_parquet_columns")
    @patch("validate_parquet.get_parquet_metadata_keys")
    @patch("validate_parquet.run_duckdb_query")
    @patch("validate_parquet.os.path.getsize", return_value=1024)
    @patch("validate_parquet.os.path.exists", return_value=True)
    def test_empty_waterways_reports_warning_not_error(
        self, mock_exists, mock_getsize, mock_query, mock_meta, mock_cols
    ):
        mock_cols.return_value = list(WATERWAY_REQUIRED_COLUMNS)
        mock_meta.return_value = list(REQUIRED_METADATA_KEYS)
        mock_query.return_value = [{
            "total_rows": 0,
            "null_id_count": 0,
            "min_osm_id": None,
            "max_osm_id": None,
            "unnamed_count": 0,
            "valid_waterway_count": 0,
        }]

        res = validate_waterways_file("MV_maldives.waterways.parquet")
        self.assertEqual(res["status"], "WARN")
        self.assertEqual(len(res["issues"]), 0)
        self.assertEqual(len(res["warnings"]), 1)
        self.assertIn("0 waterways", res["warnings"][0])

    @patch("validate_parquet.get_parquet_columns")
    @patch("validate_parquet.get_parquet_metadata_keys")
    @patch("validate_parquet.run_duckdb_query")
    @patch("validate_parquet.os.path.getsize", return_value=1024)
    @patch("validate_parquet.os.path.exists", return_value=True)
    def test_waterways_with_unnamed_reports_error(
        self, mock_exists, mock_getsize, mock_query, mock_meta, mock_cols
    ):
        mock_cols.return_value = list(WATERWAY_REQUIRED_COLUMNS)
        mock_meta.return_value = list(REQUIRED_METADATA_KEYS)
        mock_query.return_value = [{
            "total_rows": 10,
            "null_id_count": 0,
            "min_osm_id": 100,
            "max_osm_id": 200,
            "unnamed_count": 2,
            "valid_waterway_count": 10,
        }]

        res = validate_waterways_file("AT_austria.waterways.parquet")
        self.assertEqual(res["status"], "ERROR")
        self.assertIn("unnamed waterways", res["issues"][0])

    @unittest.skipUnless(os.path.exists(AT_ADDRESSES), "AT addresses fixture not present")
    def test_austria_addresses_validation(self):
        res = validate_addresses_file(AT_ADDRESSES)
        self.assertEqual(res["status"], "OK", f"Validation issues: {res['issues']}")
        self.assertGreater(res["stats"]["way_count"], 1_000_000, "Must have >1M building ways")
        self.assertGreater(res["stats"]["node_count"], 100_000, "Must have >100k address nodes")
        self.assertEqual(res["stats"]["null_id_count"], 0, "No null osm_id allowed")

    @unittest.skipUnless(os.path.exists(AT_ROADS), "AT roads fixture not present")
    def test_austria_roads_validation(self):
        res = validate_roads_file(AT_ROADS)
        self.assertEqual(res["status"], "OK", f"Validation issues: {res['issues']}")
        self.assertGreater(res["stats"]["total_rows"], 50_000, "Must have roads")
        self.assertEqual(res["stats"]["null_id_count"], 0, "No null osm_id allowed")

    @unittest.skipUnless(os.path.exists(AT_ENTRANCES), "AT entrances fixture not present")
    def test_austria_entrances_validation(self):
        res = validate_entrances_file(AT_ENTRANCES)
        self.assertEqual(res["status"], "OK", f"Validation issues: {res['issues']}")
        self.assertGreater(res["stats"]["total_rows"], 10_000, "Must have entrances")
        self.assertEqual(res["stats"]["null_id_count"], 0, "No null osm_id allowed")


if __name__ == "__main__":
    unittest.main()
