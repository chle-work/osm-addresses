-- DuckDB SQL: OSM PBF -> GeoParquet (address export)
-- Placeholder tokens __INPUT_PBF__, __OUTPUT_PARQUET__, __OSMCONF__, __COUNTRY_CODE__, __EXPORTED_AT__
-- are substituted by convert.sh using sed before the script is piped to duckdb stdin.

LOAD spatial;

COPY (
    SELECT
        street,
        number,
        postcode,
        city,
        geometry,
        osm_type,
        osm_id
    FROM (
        -- Node/point features with address tags
        SELECT
            COALESCE(addr_street, addr_place) AS street,
            addr_housenumber                  AS number,
            addr_postcode                     AS postcode,
            addr_city                         AS city,
            geom                              AS geometry,
            'node'                            AS osm_type,
            CAST(osm_id AS BIGINT)            AS osm_id
        FROM ST_Read(
            '__INPUT_PBF__',
            layer        = 'points',
            open_options = ['CONFIG_FILE=__OSMCONF__']
        )
        WHERE addr_housenumber IS NOT NULL
          AND (addr_street IS NOT NULL OR addr_place IS NOT NULL)
          AND geom IS NOT NULL

        UNION ALL

        -- Building polygon features: use representative point on surface geometry
        SELECT
            COALESCE(addr_street, addr_place) AS street,
            addr_housenumber                  AS number,
            addr_postcode                     AS postcode,
            addr_city                         AS city,
            CASE
                WHEN ST_IsValid(geom) THEN ST_PointOnSurface(geom)
                ELSE NULL
            END AS geometry,
            CASE
                WHEN osm_id IS NOT NULL THEN 'relation'
                ELSE 'way'
            END AS osm_type,
            CAST(COALESCE(osm_id, osm_way_id) AS BIGINT) AS osm_id
        FROM ST_Read(
            '__INPUT_PBF__',
            layer        = 'multipolygons',
            open_options = ['CONFIG_FILE=__OSMCONF__']
        )
        WHERE addr_housenumber IS NOT NULL
          AND (addr_street IS NOT NULL OR addr_place IS NOT NULL)
          AND ST_IsValid(geom)
          AND geom IS NOT NULL
    )
    WHERE geometry IS NOT NULL
    ORDER BY ST_Hilbert(geometry)
) TO '__OUTPUT_PARQUET__' (
    FORMAT PARQUET,
    COMPRESSION 'ZSTD',
    KV_METADATA {
        'source': 'OpenStreetMap',
        'origin': 'OpenStreetMap (https://www.openstreetmap.org)',
        'dataset': 'OpenStreetMap Addresses',
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
