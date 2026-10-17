-- DuckDB SQL: OSM PBF -> GeoParquet (linear waterways export)
-- Placeholder tokens __INPUT_PBF__, __OUTPUT_PARQUET__, __OSMCONF__, __COUNTRY_CODE__, __EXPORTED_AT__, __OSM_DATA_TIMESTAMP__, __WATERWAYS_RELS_JSON__
-- are substituted by convert.sh using sed before the script is piped to duckdb stdin.

LOAD spatial;

-- Parse GDAL other_tags HSTORE string into MAP(VARCHAR, VARCHAR)
CREATE OR REPLACE MACRO hstore_to_map(hstore_str) AS
CASE
    WHEN hstore_str IS NULL OR trim(hstore_str) = '' THEN CAST(NULL AS MAP(VARCHAR, VARCHAR))
    ELSE
        map(
            [replace(split_part(p, '"=>"', 1), '\"', '"') for p in string_split(trim(hstore_str, '"'), '","')],
            [replace(split_part(p, '"=>"', 2), '\"', '"') for p in string_split(trim(hstore_str, '"'), '","')]
        )
END;

-- Extract localized & alternative names into MAP(VARCHAR, VARCHAR) ('en', 'de', 'alt_name', etc.)
CREATE OR REPLACE MACRO extract_alt_names(props) AS
CASE
    WHEN props IS NULL THEN CAST(NULL AS MAP(VARCHAR, VARCHAR))
    ELSE
        CASE 
            WHEN len([k for k in map_keys(props)
                      if ((k LIKE 'name:%' AND k NOT LIKE 'name:%:%' AND substring(k, 6) NOT IN ('etymology', 'source', 'botanical', 'prefix', 'genitive', 'left', 'right', 'signed'))
                          OR k IN ('alt_name', 'int_name', 'official_name', 'loc_name', 'reg_name', 'short_name', 'old_name'))
                         AND props[k] IS NOT NULL AND props[k] != '']) = 0
            THEN CAST(NULL AS MAP(VARCHAR, VARCHAR))
            ELSE
                map(
                    [CASE WHEN k LIKE 'name:%' THEN substring(k, 6) ELSE k END for k in map_keys(props)
                     if ((k LIKE 'name:%' AND k NOT LIKE 'name:%:%' AND substring(k, 6) NOT IN ('etymology', 'source', 'botanical', 'prefix', 'genitive', 'left', 'right', 'signed'))
                         OR k IN ('alt_name', 'int_name', 'official_name', 'loc_name', 'reg_name', 'short_name', 'old_name'))
                        AND props[k] IS NOT NULL AND props[k] != ''],
                    [props[k] for k in map_keys(props)
                     if ((k LIKE 'name:%' AND k NOT LIKE 'name:%:%' AND substring(k, 6) NOT IN ('etymology', 'source', 'botanical', 'prefix', 'genitive', 'left', 'right', 'signed'))
                         OR k IN ('alt_name', 'int_name', 'official_name', 'loc_name', 'reg_name', 'short_name', 'old_name'))
                        AND props[k] IS NOT NULL AND props[k] != '']
                )
        END
END;

-- Build way tags map avoiding overwriting non-null relation names with NULL
CREATE OR REPLACE MACRO build_way_tags(name, waterway, other_tags_str) AS
map_concat(
    CASE 
        WHEN name IS NOT NULL THEN map(['name', 'waterway'], [name, waterway])
        ELSE map(['waterway'], [waterway])
    END,
    hstore_to_map(other_tags_str)
);

-- Build relation membership index from pre-indexed JSONL relations stream
CREATE TEMP TABLE IF NOT EXISTS waterway_rel_members AS
SELECT
    CAST(way_id AS BIGINT) AS way_id,
    CAST(relation_id AS BIGINT) AS relation_id,
    member_role,
    rel_tags
FROM read_json(
    '__WATERWAYS_RELS_JSON__',
    columns={
        'way_id': 'BIGINT',
        'relation_id': 'BIGINT',
        'member_role': 'VARCHAR',
        'rel_tags': 'MAP(VARCHAR, VARCHAR)'
    }
);

COPY (
    SELECT
        CAST(w.osm_id AS BIGINT) AS osm_id,
        'way'                    AS osm_type,
        COALESCE(w.name, r.rel_tags['name']) AS name,
        w.waterway               AS waterway,
        r.relation_id            AS relation_id,
        r.member_role            AS member_role,
        map_concat(
            extract_alt_names(r.rel_tags),
            extract_alt_names(hstore_to_map(w.other_tags))
        )                        AS alt_names,
        map_concat(
            r.rel_tags,
            build_way_tags(w.name, w.waterway, w.other_tags)
        )                        AS tags,
        w.geom                   AS geometry
    FROM ST_Read(
        '__INPUT_PBF__',
        layer        = 'lines',
        open_options = ['CONFIG_FILE=__OSMCONF__', 'INTERLEAVED_READING=YES']
    ) w
    LEFT JOIN waterway_rel_members r ON CAST(w.osm_id AS BIGINT) = r.way_id
    WHERE w.geom IS NOT NULL
      AND ST_IsValid(w.geom)
      AND w.waterway IN ('river', 'canal', 'stream')
      AND COALESCE(w.name, r.rel_tags['name']) IS NOT NULL
    ORDER BY ST_Hilbert(ST_Centroid(w.geom))
) TO '__OUTPUT_PARQUET__' (
    FORMAT PARQUET,
    COMPRESSION 'ZSTD',
    KV_METADATA {
        'source': 'OpenStreetMap',
        'origin': 'OpenStreetMap (https://www.openstreetmap.org)',
        'dataset': 'OpenStreetMap Waterways',
        'attribution': '© OpenStreetMap contributors',
        'attribution_url': 'https://www.openstreetmap.org/copyright',
        'license': 'ODbL-1.0 (https://opendatacommons.org/licenses/odbl/)',
        'license_url': 'https://opendatacommons.org/licenses/odbl/',
        'copyright': 'Data © OpenStreetMap contributors, licensed under Open Data Commons Open Database License 1.0 (ODbL)',
        'schema': 'https://github.com/krizleebear/osm-addresses',
        'schema_url': 'https://github.com/krizleebear/osm-addresses',
        'compiler': 'osm-addresses (https://github.com/krizleebear/osm-addresses)',
        'country_code': '__COUNTRY_CODE__',
        'exported_at': '__EXPORTED_AT__',
        'osm_data_timestamp': '__OSM_DATA_TIMESTAMP__'
    }
);
