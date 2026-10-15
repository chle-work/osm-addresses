-- DuckDB SQL: OSM PBF -> GeoParquet (linear waterways export)
-- Placeholder tokens __INPUT_PBF__, __OUTPUT_PARQUET__, __OSMCONF__, __COUNTRY_CODE__, __EXPORTED_AT__, __OSM_DATA_TIMESTAMP__
-- are substituted by convert.sh using sed before the script is piped to duckdb stdin.

LOAD spatial;

COPY (
    SELECT
        CAST(osm_id AS BIGINT) AS osm_id,
        'way'                  AS osm_type,
        name                   AS name,
        waterway               AS waterway,
        geom                   AS geometry
    FROM ST_Read(
        '__INPUT_PBF__',
        layer        = 'lines',
        open_options = ['CONFIG_FILE=__OSMCONF__', 'INTERLEAVED_READING=YES']
    )
    WHERE geom IS NOT NULL
      AND ST_IsValid(geom)
      AND waterway IN ('river', 'canal', 'stream')
      AND name IS NOT NULL
    ORDER BY ST_Hilbert(ST_Centroid(geom))
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
