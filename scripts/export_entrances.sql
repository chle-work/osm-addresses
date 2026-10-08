-- DuckDB SQL: OSM PBF -> GeoParquet (entrances and access gates export)
-- Placeholder tokens __INPUT_PBF__, __OUTPUT_PARQUET__, __OSMCONF__, __COUNTRY_CODE__, __EXPORTED_AT__
-- are substituted by convert.sh using sed before the script is piped to duckdb stdin.

LOAD spatial;

COPY (
    SELECT
        CAST(osm_id AS BIGINT) AS osm_id,
        'node'                 AS osm_type,
        name                   AS name,
        ref                    AS ref,
        entrance               AS entrance,
        barrier                AS barrier,
        addr_street            AS street,
        addr_housenumber       AS housenumber,
        geom                   AS geometry
    FROM ST_Read(
        '__INPUT_PBF__',
        layer        = 'points',
        open_options = ['CONFIG_FILE=__OSMCONF__']
    )
    WHERE geom IS NOT NULL
      AND (
          (entrance IS NOT NULL AND entrance NOT IN ('no'))
          OR barrier IN ('gate', 'lift_gate')
      )
    ORDER BY ST_Hilbert(geom)
) TO '__OUTPUT_PARQUET__' (
    FORMAT PARQUET,
    COMPRESSION 'ZSTD',
    KV_METADATA {
        'source': 'OpenStreetMap',
        'origin': 'OpenStreetMap (https://www.openstreetmap.org)',
        'dataset': 'OpenStreetMap Entrances',
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
