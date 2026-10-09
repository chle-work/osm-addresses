#!/usr/bin/env python3
"""
Unit tests for configuration, SQL templates, and pipeline invariants.

Verifies:
  1. Parquet Provenance & License Metadata Invariant (Rule 11) across all SQL templates.
  2. GDAL Interleaved Reading & Buffer Isolation Invariant (Rule 12):
     ST_Read calls must specify INTERLEAVED_READING=YES.
  3. osmconf.ini Multipolygons Way ID Safety (Rule 12):
     [multipolygons] must specify osm_way_id=yes.
  4. Tag Pre-filtering & Runner Disk Conservation Invariant (Rule 5):
     azure-pipelines.yml must filter into separate PBF layers and clean up raw PBFs.
  5. GDAL Node Cache Headroom Invariant (Rule 12):
     convert.sh must export OSM_MAX_TMPFILE_SIZE >= 4096 and OSM_COMPRESS_NODES=YES.
"""

import configparser
import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SQL_TEMPLATES = (
    os.path.join(REPO_ROOT, "scripts", "export_addresses.sql"),
    os.path.join(REPO_ROOT, "scripts", "export_roads.sql"),
    os.path.join(REPO_ROOT, "scripts", "export_entrances.sql"),
)

OSMCONF_INI = os.path.join(REPO_ROOT, "scripts", "osmconf.ini")
CONVERT_SH = os.path.join(REPO_ROOT, "scripts", "convert.sh")
PIPELINE_YAML = os.path.join(REPO_ROOT, "azure-pipelines.yml")
RELEASE_PIPELINE_YAML = os.path.join(REPO_ROOT, "azure-pipelines-release.yml")
OSM2PARQUET_VERSION_TEMPLATE = os.path.join(
    REPO_ROOT,
    "templates",
    "osm2parquet-version.yml",
)

REQUIRED_METADATA_KEYS = (
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
)


def read_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


class TestContainerVersionConfiguration(unittest.TestCase):
    """Only the build job needs the centrally pinned DuckDB container."""

    def test_build_imports_the_shared_container_version_template(self):
        expected_template = "- template: templates/osm2parquet-version.yml"
        expected_image = "image: ghcr.io/krizleebear/osm2parquet:$(OSM2PARQUET_VERSION)"

        self.assertTrue(
            os.path.isfile(OSM2PARQUET_VERSION_TEMPLATE),
            "shared osm2parquet version template must exist",
        )
        self.assertIn(
            "OSM2PARQUET_VERSION: 'v",
            read_file(OSM2PARQUET_VERSION_TEMPLATE),
            "shared template must pin OSM2PARQUET_VERSION",
        )
        pipeline_content = read_file(PIPELINE_YAML)
        self.assertIn(expected_template, pipeline_content)
        self.assertIn(expected_image, pipeline_content)

    def test_release_pipeline_does_not_require_the_osm2parquet_container(self):
        release_content = read_file(RELEASE_PIPELINE_YAML)
        self.assertNotIn("osm2parquet", release_content)

    def test_build_warmup_uses_the_shared_container_version(self):
        pipeline_content = read_file(PIPELINE_YAML)
        self.assertIn(
            'GHCR_IMAGE="ghcr.io/krizleebear/osm2parquet:$(OSM2PARQUET_VERSION)"',
            pipeline_content,
        )
        self.assertIn(
            'MIRROR_IMAGE="mirror.gcr.io/krizleebear/osm2parquet:$(OSM2PARQUET_VERSION)"',
            pipeline_content,
        )


class TestSqlTemplatesMetadata(unittest.TestCase):
    """Rule 11: All export SQL templates must embed complete KV_METADATA."""

    def test_sql_templates_embed_all_kv_metadata_keys(self):
        for sql_path in SQL_TEMPLATES:
            content = read_file(sql_path)
            rel_path = os.path.relpath(sql_path, REPO_ROOT)
            self.assertIn(
                "KV_METADATA",
                content,
                f"{rel_path} does not specify KV_METADATA in COPY statement",
            )
            for key in REQUIRED_METADATA_KEYS:
                self.assertIn(
                    f"'{key}'",
                    content,
                    f"{rel_path} is missing mandatory KV_METADATA key '{key}'",
                )


class TestGdalInterleavedReading(unittest.TestCase):
    """Rule 12: All ST_Read calls must specify INTERLEAVED_READING=YES."""

    def test_st_read_specifies_interleaved_reading(self):
        st_read_pattern = re.compile(r"ST_Read\s*\(([^)]+)\)", re.IGNORECASE | re.DOTALL)
        for sql_path in SQL_TEMPLATES:
            content = read_file(sql_path)
            rel_path = os.path.relpath(sql_path, REPO_ROOT)
            matches = list(st_read_pattern.finditer(content))
            self.assertGreater(
                len(matches),
                0,
                f"{rel_path} must contain at least one ST_Read call",
            )
            for match in matches:
                call_args = match.group(1)
                self.assertIn(
                    "INTERLEAVED_READING=YES",
                    call_args,
                    f"{rel_path} ST_Read call is missing 'INTERLEAVED_READING=YES':\n{call_args.strip()}",
                )
                self.assertIn(
                    "CONFIG_FILE=__OSMCONF__",
                    call_args,
                    f"{rel_path} ST_Read call is missing 'CONFIG_FILE=__OSMCONF__':\n{call_args.strip()}",
                )


class TestOsmconfConfiguration(unittest.TestCase):
    """Rule 12: osmconf.ini must enable osm_way_id under [multipolygons]."""

    def setUp(self):
        self.config = configparser.ConfigParser()
        content = read_file(OSMCONF_INI)
        # osmconf.ini has global options before the first section header.
        # Wrap with a [GLOBAL] header for configparser compatibility.
        self.config.read_string("[GLOBAL]\n" + content)

    def test_multipolygons_enables_osm_way_id(self):
        self.assertTrue(
            self.config.has_section("multipolygons"),
            "osmconf.ini must have a [multipolygons] section",
        )
        self.assertTrue(
            self.config.has_option("multipolygons", "osm_way_id"),
            "osmconf.ini [multipolygons] must contain 'osm_way_id'",
        )
        self.assertEqual(
            self.config.get("multipolygons", "osm_way_id").strip().lower(),
            "yes",
            "osmconf.ini [multipolygons] osm_way_id must be set to 'yes' to prevent building way ID loss",
        )

    def test_required_sections_exist(self):
        for section in ("points", "lines", "multipolygons"):
            self.assertTrue(
                self.config.has_section(section),
                f"osmconf.ini missing required [{section}] section",
            )


class TestPipelineLayerFiltering(unittest.TestCase):
    """Rule 5: Dedicated per-layer PBF filtering and runner disk conservation."""

    def setUp(self):
        self.pipeline_content = read_file(PIPELINE_YAML)

    def test_separate_layer_pbfs_defined(self):
        self.assertIn(
            'ADDRESSES_PBF="$(COUNTRY_CODE)_$(OSM_REGION).addresses.pbf"',
            self.pipeline_content,
            "azure-pipelines.yml must define dedicated ADDRESSES_PBF",
        )
        self.assertIn(
            'ROADS_PBF="$(COUNTRY_CODE)_$(OSM_REGION).roads.pbf"',
            self.pipeline_content,
            "azure-pipelines.yml must define dedicated ROADS_PBF",
        )
        self.assertIn(
            'ENTRANCES_PBF="$(COUNTRY_CODE)_$(OSM_REGION).entrances.pbf"',
            self.pipeline_content,
            "azure-pipelines.yml must define dedicated ENTRANCES_PBF",
        )

    def test_osmium_filters_three_distinct_layers(self):
        self.assertIn(
            'osmium tags-filter "$INPUT_PBF" \\\n              n/addr:housenumber wr/addr:housenumber \\\n              -o "$ADDRESSES_PBF"',
            self.pipeline_content,
            "azure-pipelines.yml must filter addresses separately",
        )
        self.assertIn(
            'osmium tags-filter "$INPUT_PBF" \\\n              w/highway=',
            self.pipeline_content,
            "azure-pipelines.yml must filter roads separately",
        )
        self.assertIn(
            'osmium tags-filter "$INPUT_PBF" \\\n              n/entrance n/barrier=gate,lift_gate \\\n              -o "$ENTRANCES_PBF"',
            self.pipeline_content,
            "azure-pipelines.yml must filter entrances separately",
        )

    def test_raw_pbf_reclaimed_immediately(self):
        self.assertIn(
            'rm -rf "osm-data-$(OSM_REGION)" "$(OSM_REGION).osm.pbf"',
            self.pipeline_content,
            "azure-pipelines.yml must reclaim raw PBF disk space immediately after filtering",
        )

    def test_convert_sh_invoked_with_three_layer_pbfs(self):
        self.assertIn(
            './scripts/convert.sh "$ADDRESSES_PBF" "$ROADS_PBF" "$ENTRANCES_PBF"',
            self.pipeline_content,
            "convert.sh must be invoked with 3 dedicated layer PBF arguments",
        )

    def test_oversized_parquets_are_partitioned_before_artifact_publication(self):
        splitter_command = "python3 scripts/split_oversized_parquet.py . --max-size-mb 1800"
        validation_command = 'python3 scripts/validate_parquet.py "$(COUNTRY_CODE)_$(OSM_REGION)".*.parquet --fail-on-error'
        artifact_copy = 'cp "$(COUNTRY_CODE)_$(OSM_REGION)".*.parquet "artifacts-$(COUNTRY_CODE)-$(OSM_REGION)/"'

        self.assertIn(splitter_command, self.pipeline_content)
        self.assertEqual(
            self.pipeline_content.count(validation_command),
            2,
            "build must validate both original exports and publishable files after partitioning",
        )
        first_validation = self.pipeline_content.index(validation_command)
        second_validation = self.pipeline_content.index(validation_command, first_validation + 1)
        self.assertLess(
            first_validation,
            self.pipeline_content.index(splitter_command),
            "build must validate original exports before partitioning them",
        )
        self.assertLess(
            self.pipeline_content.index(splitter_command),
            second_validation,
            "build must validate the partitioned outputs after partitioning",
        )
        self.assertLess(
            second_validation,
            self.pipeline_content.index(artifact_copy),
            "build must validate publishable outputs before artifact copying",
        )
        self.assertNotIn(
            "split_oversized_parquet.py",
            read_file(RELEASE_PIPELINE_YAML),
            "release aggregation must not partition all country assets on one disk",
        )


class TestConvertScriptInvariants(unittest.TestCase):
    """Rule 12: convert.sh node cache and compression settings."""

    def setUp(self):
        self.script_content = read_file(CONVERT_SH)

    def test_node_cache_size_headroom(self):
        self.assertIn(
            'OSM_MAX_TMPFILE_SIZE="${OSM_MAX_TMPFILE_SIZE:-4096}"',
            self.script_content,
            "convert.sh must export OSM_MAX_TMPFILE_SIZE with default 4096",
        )

    def test_node_compression_enabled(self):
        self.assertIn(
            'OSM_COMPRESS_NODES="${OSM_COMPRESS_NODES:-YES}"',
            self.script_content,
            "convert.sh must export OSM_COMPRESS_NODES with default YES",
        )


if __name__ == "__main__":
    unittest.main()
