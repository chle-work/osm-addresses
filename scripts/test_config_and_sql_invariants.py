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
    os.path.join(REPO_ROOT, "scripts", "export_waterways.sql"),
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
    "osm_data_timestamp",
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

    def test_convert_sh_substitutes_osm_data_timestamp(self):
        content = read_file(CONVERT_SH)
        self.assertIn(
            "__OSM_DATA_TIMESTAMP__",
            content,
            "convert.sh must substitute __OSM_DATA_TIMESTAMP__ placeholder",
        )

    def test_convert_sh_substitutes_waterways_rels_json(self):
        content = read_file(CONVERT_SH)
        self.assertIn(
            "__WATERWAYS_RELS_JSON__",
            content,
            "convert.sh must substitute __WATERWAYS_RELS_JSON__ placeholder",
        )

    def test_waterways_rels_json_not_in_duckdb_temp_dir(self):
        content = read_file(CONVERT_SH)
        self.assertNotIn(
            'WATERWAYS_RELS_JSON="${DUCKDB_TEMP_DIR}/',
            content,
            "WATERWAYS_RELS_JSON must not be placed in DUCKDB_TEMP_DIR because reset_scratch_dirs wipes it",
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

    def test_lines_enables_waterway(self):
        self.assertTrue(
            self.config.has_section("lines"),
            "osmconf.ini must have a [lines] section",
        )
        attributes = [a.strip() for a in self.config.get("lines", "attributes").split(",")]
        self.assertIn("waterway", attributes, "osmconf.ini [lines] must expose 'waterway' attribute")

    def test_lines_enables_other_tags(self):
        self.assertTrue(
            self.config.has_section("lines"),
            "osmconf.ini must have a [lines] section",
        )
        self.assertEqual(
            self.config.get("lines", "other_tags").strip().lower(),
            "yes",
            "osmconf.ini [lines] must set 'other_tags=yes' to expose multilingual and raw tags",
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
        self.assertIn(
            'WATERWAYS_PBF="$(COUNTRY_CODE)_$(OSM_REGION).waterways.pbf"',
            self.pipeline_content,
            "azure-pipelines.yml must define dedicated WATERWAYS_PBF",
        )

    def test_osmium_filters_distinct_layers(self):
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
        self.assertIn(
            'osmium tags-filter "$INPUT_PBF" \\\n              wr/waterway=river,canal,stream r/type=waterway \\\n              -o "$WATERWAYS_PBF"',
            self.pipeline_content,
            "azure-pipelines.yml must filter waterways separately",
        )

    def test_raw_pbf_reclaimed_immediately(self):
        self.assertIn(
            'rm -rf "osm-data-$(OSM_REGION)" "$(OSM_REGION).osm.pbf"',
            self.pipeline_content,
            "azure-pipelines.yml must reclaim raw PBF disk space immediately after filtering",
        )

    def test_convert_sh_invoked_with_four_layer_pbfs(self):
        self.assertIn(
            './scripts/convert.sh "$ADDRESSES_PBF" "$ROADS_PBF" "$ENTRANCES_PBF" "$WATERWAYS_PBF"',
            self.pipeline_content,
            "convert.sh must be invoked with 4 dedicated layer PBF arguments",
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


class TestWaterwaysSqlInvariants(unittest.TestCase):
    """Invariants for waterways export: relation membership, alt_names, and tags."""

    def setUp(self):
        sql_path = os.path.join(REPO_ROOT, "scripts", "export_waterways.sql")
        self.sql_content = read_file(sql_path)

    def test_waterways_sql_selects_expected_columns(self):
        for col in ("relation_id", "member_role", "alt_names", "tags", "waterway", "bbox_minx", "bbox_miny", "bbox_maxx", "bbox_maxy", "geometry"):
            self.assertIn(
                col,
                self.sql_content,
                f"export_waterways.sql must project '{col}' column",
            )

    def test_waterways_sql_defines_required_macros(self):
        for macro_name in ("hstore_to_map", "extract_alt_names", "build_way_tags"):
            self.assertIn(
                f"MACRO {macro_name}",
                self.sql_content,
                f"export_waterways.sql must define MACRO {macro_name}",
            )

    def test_waterways_sql_joins_relation_members(self):
        self.assertIn(
            "waterway_rel_members",
            self.sql_content,
            "export_waterways.sql must build and join waterway_rel_members",
        )
        self.assertIn(
            "__WATERWAYS_RELS_JSON__",
            self.sql_content,
            "export_waterways.sql must reference __WATERWAYS_RELS_JSON__ placeholder",
        )

    def test_waterways_macros_duckdb_execution(self):
        import shutil
        import subprocess

        if not shutil.which("duckdb"):
            self.skipTest("duckdb CLI not available on host")

        # Extract macro definitions directly from export_waterways.sql
        macro_sql_chunk = self.sql_content.split("CREATE TEMP TABLE")[0]
        # Strip LOAD spatial so tests run without spatial extension installed on host
        macro_sql = "\n".join(
            line for line in macro_sql_chunk.splitlines()
            if not line.strip().startswith("LOAD spatial")
        )

        test_query = f"""
        {macro_sql}

        SELECT
            map_concat(
                extract_alt_names(map(['name:en', 'name:fr'], ['Danube', 'Danube'])),
                extract_alt_names(hstore_to_map('"alt_name"=>"Danubius","name:de"=>"Donau"'))
            ) AS alt_names,
            hstore_to_map('"seasonal"=>"yes","width"=>"3"') AS way_tags;
        """
        proc = subprocess.run(
            ["duckdb", "-dark-mode", "-no-stdin", "-json", "-c", test_query],
            capture_output=True,
            text=True,
            check=True,
        )
        import json
        rows = json.loads(proc.stdout)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        alt_names = row["alt_names"]
        self.assertEqual(alt_names.get("en"), "Danube")
        self.assertEqual(alt_names.get("fr"), "Danube")
        self.assertEqual(alt_names.get("de"), "Donau")
        self.assertEqual(alt_names.get("alt_name"), "Danubius")

        # Regression assertions for HSTORE quote splitting
        way_tags = row["way_tags"]
        self.assertEqual(way_tags.get("seasonal"), "yes")
        self.assertEqual(way_tags.get("width"), "3")
        self.assertNotIn('seasonal"=>"yes', way_tags)

    def test_index_waterway_relations_parser(self):
        import sys
        import io
        import json
        import subprocess

        # Simulated Osmium OPL output including Unicode code points (Amharic ራይን ወን, German, etc.)
        mock_opl = (
            "r123924 v1 dV c1 t1 i1 u1 "
            "Tname=Rhein,name:am=%122b%%12ed%%1295%%20%%12c8%%1295%,name:en=Rhine,name:de=Rhein%2c%%20%Hauptfluss "
            "Mw1524365679@main_stream,w1417928672@\n"
            "r999 v1 dV c1 t1 i1 u1 Tname=SubStream Mw1524365679@side_stream\n"
        )
        script_path = os.path.join(REPO_ROOT, "scripts", "index_waterway_relations.py")
        proc = subprocess.run(
            [sys.executable, script_path],
            input=mock_opl,
            capture_output=True,
            text=True,
            check=True,
        )
        lines = [json.loads(line) for line in proc.stdout.strip().splitlines()]
        self.assertEqual(len(lines), 2)

        # Way 1524365679 had two candidate relations (123924 with main_stream, 999 with side_stream)
        # main_stream must win deterministically:
        by_way = {item["way_id"]: item for item in lines}
        way_entry = by_way[1524365679]
        self.assertEqual(way_entry["relation_id"], 123924)
        self.assertEqual(way_entry["member_role"], "main_stream")
        self.assertEqual(way_entry["rel_tags"]["name"], "Rhein")
        self.assertEqual(way_entry["rel_tags"]["name:en"], "Rhine")
        self.assertEqual(way_entry["rel_tags"]["name:am"], "ራይን ወን")
        self.assertEqual(way_entry["rel_tags"]["name:de"], "Rhein, Hauptfluss")


class TestSpatialOptimizationInvariants(unittest.TestCase):
    """Invariants for spatial indexing: BBox/lon-lat projection, Hilbert ordering, and Row Group Size."""

    def test_sql_templates_specify_row_group_size_50000(self):
        for template_path in SQL_TEMPLATES:
            basename = os.path.basename(template_path)
            content = read_file(template_path)
            self.assertIn(
                "ROW_GROUP_SIZE 50000",
                content,
                f"{basename} must specify 'ROW_GROUP_SIZE 50000' for optimal spatial pruning",
            )

    def test_all_sql_templates_use_hilbert_sorting(self):
        for template_path in SQL_TEMPLATES:
            basename = os.path.basename(template_path)
            content = read_file(template_path)
            self.assertRegex(
                content,
                r"ORDER BY ST_Hilbert\([^,]+,\s*ST_Extent\(ST_MakeEnvelope\(",
                f"{basename} must order output by bounded ST_Hilbert(..., ST_Extent(ST_MakeEnvelope(...))) for accurate spatial clustering without window buffering overhead",
            )

    def test_roads_sql_projects_bbox_columns(self):
        roads_sql = read_file(os.path.join(REPO_ROOT, "scripts", "export_roads.sql"))
        for col in ("bbox_minx", "bbox_miny", "bbox_maxx", "bbox_maxy"):
            self.assertIn(col, roads_sql, f"export_roads.sql must project '{col}'")

    def test_addresses_sql_projects_lon_lat(self):
        addr_sql = read_file(os.path.join(REPO_ROOT, "scripts", "export_addresses.sql"))
        for col in ("lon", "lat"):
            self.assertIn(col, addr_sql, f"export_addresses.sql must project '{col}'")

    def test_entrances_sql_projects_lon_lat(self):
        entr_sql = read_file(os.path.join(REPO_ROOT, "scripts", "export_entrances.sql"))
        for col in ("lon", "lat"):
            self.assertIn(col, entr_sql, f"export_entrances.sql must project '{col}'")


if __name__ == "__main__":
    unittest.main()
