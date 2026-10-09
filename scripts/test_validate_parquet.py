#!/usr/bin/env python3
"""
Unit tests for validate_parquet.py.
"""

import os
import unittest

from validate_parquet import (
    validate_addresses_file,
    validate_roads_file,
    validate_entrances_file,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AT_DIR = os.path.join(REPO_ROOT, "osm-parquet-AT-austria")
AT_ADDRESSES = os.path.join(AT_DIR, "AT_austria.addresses.parquet")
AT_ROADS = os.path.join(AT_DIR, "AT_austria.roads.parquet")
AT_ENTRANCES = os.path.join(AT_DIR, "AT_austria.entrances.parquet")


class TestValidateParquet(unittest.TestCase):

    def test_missing_file_reports_error(self):
        res = validate_addresses_file("nonexistent.parquet")
        self.assertEqual(res["status"], "ERROR")
        self.assertIn("File missing or 0 bytes", res["issues"])

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
