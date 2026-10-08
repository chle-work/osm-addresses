# 🛣️ Upstream Data Contract: Road Centerlines & Entrance Nodes (`osm-roads` & `osm-entrances`)

**Dataset Targets:** `{ISO}_{name}.roads.parquet`, `{ISO}_{name}.entrances.parquet`  
**Upstream Repository:** `krizleebear/osm-addresses` (oder PBF-Extraktor)  
**Format:** GeoParquet 1.0+ (Apache Parquet mit WKB `geometry`, CRS EPSG:4326 / OGC:CRS84, ZSTD komprimiert)  
**Downstream Consumer:** `osm-geocoder` (Address Access Point Snapping, Idee #48)  

---

## 📌 1. Übersicht & Zielsetzung

Für die Berechnung von verifizierten **Access Points** (Haltelinien / Curb-Arrival-Punkte auf der Straße für Hausnummern) benötigt der `osm-geocoder` zwei neue räumliche Layer pro Land/Region:

1. **`osm-roads`**: Befahrbare Straßenachsen (`LineString`), auf die Adresspunkte oder Eingänge orthogonal projiziert werden.
2. **`osm-entrances`**: Physische Eingangs- und Zufahrtsknoten (`Point`), um bei großen Grundstücken oder Eckhäusern den Anfahrtspunkt vor der tatsächlichen Haustür zu verankern.

Die Bereitstellung soll analog zu den bestehenden `{ISO}_{name}.addresses.parquet`-Dateien pro Land erfolgen.

---

## 📦 2. Dateistruktur & Namenskonvention

Die Dateien folgen exakt der Partitionierung und Namenskonvention von `osm-addresses`:

```
data/
├── osm-addresses/
│   ├── DE_germany.addresses.parquet
│   └── MC_monaco.addresses.parquet
├── osm-roads/
│   ├── DE_germany.roads.parquet
│   └── MC_monaco.roads.parquet
└── osm-entrances/
    ├── DE_germany.entrances.parquet
    └── MC_monaco.entrances.parquet
```

---

## 🛣️ 3. Spezifikation: `osm-roads` (`LineString`)

Erfasst das routing-relevante, für Kraftfahrzeuge befahrbare Straßennetzwerk.

### 3.1 Tabellenschema

| Spalte | DuckDB / Parquet Typ | Pflicht | Beschreibung / Beispiel |
| :--- | :--- | :---: | :--- |
| `osm_id` | `BIGINT` | Ja | Numerische OSM Way-ID. |
| `osm_type` | `VARCHAR` | Ja | Strikt `'way'` (keine Relationen, um Geometrieduplikate zu vermeiden). |
| `name` | `VARCHAR` | Nein | Straßenname (`name`-Tag in OSM, z. B. `'Hauptstraße'`). `NULL` bei unbenannten Straßen. |
| `highway` | `VARCHAR` | Ja | OSM `highway`-Klassifikation (z. B. `'residential'`, `'service'`). |
| `oneway` | `VARCHAR` | Nein | Normalisiertes Einbahnstraßen-Flag (`'yes'`, `'no'`, `'-1'`, sonst `NULL`). |
| `service` | `VARCHAR` | Nein | Untertyp bei `highway=service` (z. B. `'driveway'`, `'alley'`, `'parking_aisle'`). |
| `geometry` | `GEOMETRY` | Ja | WKB `LineString` oder `MultiLineString` in WGS84 (`EPSG:4326`). |

### 3.2 Extraktions- & Filterregeln (PKW-Netzwerk)

* **Einschluss (Whitelist `highway`):**
  ```sql
  WHERE (
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
      -- Fußgängerzonen mit Lieferverkehr / Anliegerzufahrt einbeziehen:
      OR (
          highway = 'pedestrian'
          AND COALESCE(access, motor_vehicle, motorcar) IN ('destination', 'delivery', 'yes', 'permissive')
      )
      -- Benannte Wirtschaftswege einbeziehen (Anbindung ländlicher Adressen):
      OR (
          highway = 'track'
          AND name IS NOT NULL
      )
  )
  ```
* **Ausschluss (Blacklist):**
  - **Keine reinen Fuß-/Radwege:** `footway`, `cycleway`, `path`, `steps`, `bridleway`, `corridor`, `elevator`, `platform`.
  - **Keine Autobahnen:** `motorway`, `motorway_link` (Adressen besitzen keine direkten Haltepunkte auf Autobahnen).
  - **Keine Bau-/Planungsstraßen:** `construction`, `proposed`, `abandoned`, `raceway`.
  - **Kraftfahrzeug-Zugangsbeschränkungen:** Abschnitte mit `access = 'no'`, `motor_vehicle = 'no'` oder `motorcar = 'no'` ausschließen (außer bei expliziter Freigabe wie `destination`/`delivery`).

---

## 🚪 4. Spezifikation: `osm-entrances` (`Point`)

Erfasst alle explizit kartierten Eingänge, Türen und Tore.

### 4.1 Tabellenschema

| Spalte | DuckDB / Parquet Typ | Pflicht | Beschreibung / Beispiel |
| :--- | :--- | :---: | :--- |
| `osm_id` | `BIGINT` | Ja | Numerische OSM Node-ID. |
| `osm_type` | `VARCHAR` | Ja | Immer `'node'`. |
| `name` | `VARCHAR` | Nein | Name des Eingangs (z. B. `'Haupteingang'`). |
| `ref` | `VARCHAR` | Nein | Referenz-/Aufgangsbezeichnung (z. B. `'Aufgang A'`, `'1'`, `'Nord'`). |
| `entrance` | `VARCHAR` | Ja | Wert des `entrance`-Tags (z. B. `'main'`, `'yes'`, `'staircase'`, `'home'`, `'shop'`, `'garage'`). |
| `barrier` | `VARCHAR` | Nein | Wert des `barrier`-Tags bei Toren/Schranken (z. B. `'gate'`, `'lift_gate'`). |
| `street` | `VARCHAR` | Nein | `addr:street` direkt am Eingangsknoten (falls vorhanden). |
| `housenumber` | `VARCHAR` | Nein | `addr:housenumber` direkt am Eingangsknoten (falls vorhanden). |
| `geometry` | `GEOMETRY` | Ja | WKB `Point` in WGS84 (`EPSG:4326`). |

### 4.2 Extraktions- & Filterregeln

* **Eingänge (`entrance`) & Tore / Zufahrtsschranken (`barrier`):**
  ```sql
  WHERE (
      (entrance IS NOT NULL AND entrance NOT IN ('no'))
      OR barrier IN ('gate', 'lift_gate')
  )
  ```

---

## ⚡ 5. GeoParquet-Metadaten & Performance-Vorgaben

1. **Native WKB Geometrie & GeoParquet 1.0:**
   - Standard GeoParquet Metadaten-Block im Parquet-Header/Footer (`geo`-Key).
   - Geometrie-Typen strikt typisiert (`LineString` für Roads, `Point` für Entrances/Addresses).
2. **Kompression:**
   - ZSTD-Kompression für minimale Dateigrößen bei schnellem DuckDB-Lesedurchsatz.
3. **Räumliche Sortierung (Hilbert-Kurve):**
   - Zur Beschleunigung von DuckDB R-Tree Spatial Joins werden alle Layer räumlich geordnet:
     - `addresses` & `entrances`: `ORDER BY ST_Hilbert(geometry)`
     - `roads`: `ORDER BY ST_Hilbert(ST_Centroid(geometry))`
4. **Parquet Footer Metadaten (`KV_METADATA`):**
   - Standardisierte Provenienz- und Lizenz-Metadaten (ODbL, Source, Dataset, Compiler, ISO Country Code, Export Timestamp) gemäß AGENTS.md Invarianten.

---

## 🏗️ 6. CI/CD & Pipeline-Integration

1. **Single-Pass Osmium-Vorfilterung:**
   - Auf CI-Runners filtert ein einziger `osmium tags-filter`-Pass alle drei Layer (`addresses`, `roads` mit Whitelist, `entrances`) in ein kompaktes Zwischen-PBF (`$(CC)_$(REGION).combined.pbf`).
   - Das schwere Roh-PBF von Geofabrik wird sofort gelöscht, um Disk-Space-Limits (< 5 GB Peak) einzuhalten.
2. **DuckDB-Konvertierung (`osm2parquet` Container):**
   - `scripts/convert.sh` führt drei modulare SQL-Skripte aus (`scripts/export_addresses.sql`, `scripts/export_roads.sql`, `scripts/export_entrances.sql`) und erzeugt alle drei Parquet-Dateien.
3. **Pipeline-Artefakte & GitHub Releases:**
   - Jedes Matrix-Job publiziert ein gebündeltes Artefakt `osm-parquet-$(CC)-$(REGION)` mit allen 3 Parquet-Dateien.
   - Die GitHub Release Pipeline stellt alle 3 Dateien pro Land/Region direkt als Release-Assets bereit (~507 Dateien weltweit).
