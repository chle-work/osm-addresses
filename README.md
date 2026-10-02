# osm-addresses

Global address dataset extracted from OpenStreetMap, published as **GeoParquet** (ZSTD-compressed).

## Data

Each file contains all address-tagged features (`addr:housenumber` + `addr:street`) for one region:

- **Points**: OSM nodes with address tags (direct coordinates)
- **Buildings & Polygons**: OSM ways and multipolygons with address tags (centroid used as point geometry)

### Schema

| Column | Type | Description |
|:---|:---|:---|
| `street` | `varchar` | `addr:street` |
| `number` | `varchar` | `addr:housenumber` |
| `postcode` | `varchar` | `addr:postcode` |
| `city` | `varchar` | `addr:city` |
| `geometry` | `geometry('epsg:4326')` | Point geometry (WGS84 EPSG:4326) |
| `osm_type` | `varchar` | Source OSM element type (`node`, `way`, `relation`) |
| `osm_id` | `int64` | Source OSM element ID |

### Example Query (DuckDB)

```sql
LOAD spatial;
SELECT street, number, postcode, city, osm_type, osm_id, ST_AsText(geometry)
FROM read_parquet('DE_germany.addresses.parquet')
WHERE city = 'München'
LIMIT 10;
```

### Example (GeoPandas)

```python
import geopandas as gpd
gdf = gpd.read_parquet("DE_germany.addresses.parquet")
```

## Pipelines

Data is produced and published by two Azure DevOps pipelines:

1. **`azure-pipelines.yml`** (`addresses-parquet-pipeline`):  
   - Downloads cached OSM PBF extracts from the `osm-download` pipeline (definition ID 3).
   - Pre-filters address features via `osmium tags-filter` to conserve disk space.
   - Converts filtered PBFs to ZSTD-compressed GeoParquet via [DuckDB](https://duckdb.org/) spatial extension (`osm2parquet` container).
   - Publishes individual per-region GeoParquet artifacts (`addresses-parquet-$(CC)-$(REGION)`).
2. **`azure-pipelines-release.yml`** (`addresses-release-pipeline`):  
   - Manual GitHub Release pipeline (`trigger: none`).
   - Downloads latest build artifacts, prepares release notes, and publishes individual per-region GeoParquet files (`.parquet`) as GitHub Release assets.

## Coverage

**Global Coverage**: 169 region definitions spanning Africa, Asia, Europe, Oceania, Central America, North America, and South America matching the [osm-polygons](https://github.com/krizleebear/osm-polygons) dataset.

## Future Ideas & Roadmap

Potential improvements for higher address density and coverage:
- **Extended Filter Criteria & Place Fallbacks:** Include `addr:housenumber` tagged with `addr:place` (common in rural areas/hamlets lacking street names) or resolve `associatedStreet` relation references.
- **Address Interpolation:** Support OSM address interpolation lines (`addr:interpolation=all|even|odd|alphabetic`) to generate synthesized point coordinates along streets where individual building housenumbers are unmapped (~2.57M lines globally, yielding an estimated 10–20M additional addresses).
- **Unstructured Addresses:** Parse `addr:full` into structured components where individual address tags are absent.

See [ADDRESS_COVERAGE_ROADMAP.md](file:///Users/krizleebear/development/osm-addresses/doc/ADDRESS_COVERAGE_ROADMAP.md) for detailed Taginfo metrics, gap analysis, and implementation concepts.

## License

Data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), [ODbL](https://opendatacommons.org/licenses/odbl/).


