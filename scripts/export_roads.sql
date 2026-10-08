-- DuckDB SQL: OSM PBF -> GeoParquet (road centerlines export)
-- Placeholder tokens __INPUT_PBF__, __OUTPUT_PARQUET__, __OSMCONF__, __COUNTRY_CODE__, __EXPORTED_AT__
-- are substituted by convert.sh using sed before the script is piped to duckdb stdin.

LOAD spatial;

COPY (
    SELECT
        CAST(osm_id AS BIGINT) AS osm_id,
        'way'                  AS osm_type,
        name                   AS name,
        highway                AS highway,
        CASE
            WHEN oneway IN ('yes', '1', 'true') THEN 'yes'
            WHEN oneway IN ('-1', 'reverse') THEN '-1'
            WHEN oneway IN ('no', '0', 'false') THEN 'no'
            ELSE NULL
        END                    AS oneway,
        service                AS service,
        geom                   AS geometry
    FROM ST_Read(
        '__INPUT_PBF__',
        layer        = 'lines',
        open_options = ['CONFIG_FILE=__OSMCONF__', 'INTERLEAVED_READING=YES']
    )
    WHERE geom IS NOT NULL
      AND ST_IsValid(geom)
      AND (
          highway IN (
              'residential',
              'unclassified',
              'tertiary',
              'tertiary_link',
              'secondary',
              'secondary_link',
              'primary',
              'primary_link',
              'trunk',
              'trunk_link',
              'living_street',
              'service'
          )
          OR (
              highway = 'pedestrian'
              AND COALESCE(access, motor_vehicle, motorcar) IN ('destination', 'delivery', 'yes', 'permissive')
          )
          OR (
              highway = 'track'
              AND name IS NOT NULL
          )
      )
      -- Exclude sections where motor vehicular access is prohibited
      AND (access IS NULL OR access NOT IN ('no'))
      AND (motor_vehicle IS NULL OR motor_vehicle NOT IN ('no'))
      AND (motorcar IS NULL OR motorcar NOT IN ('no'))
    ORDER BY ST_Hilbert(ST_Centroid(geom))
) TO '__OUTPUT_PARQUET__' (
    FORMAT PARQUET,
    COMPRESSION 'ZSTD',
    KV_METADATA {
        'source': 'OpenStreetMap',
        'origin': 'OpenStreetMap (https://www.openstreetmap.org)',
        'dataset': 'OpenStreetMap Roads',
        'attribution': '© OpenStreetMap contributors',
        'attribution_url': 'https://www.openstreetmap.org/copyright',
        'license': 'ODbL-1.0 (https://opendatacommons.org/licenses/odbl/)',
        'license_url': 'https://opendatacommons.org/licenses/odbl/',
        'copyright': 'Data © OpenStreetMap contributors, licensed under Open Data Commons Open Database License 1.0 (ODbL)',
        'schema': 'https://github.com/krizleebear/osm-addresses',
        'schema_url': 'https://github.com/krizleebear/osm-addresses',
        'compiler': 'osm-addresses (https://github.com/krizleebear/osm-addresses)',
        'country_code': '__COUNTRY_CODE__',
        'exported_at': '__EXPORTED_AT__'
    }
);
