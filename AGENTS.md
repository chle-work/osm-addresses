# AGENTS.md — Development Guidelines for `osm-addresses`

To ensure consistent pipeline execution, geographical coverage, and clean Git workflows in `osm-addresses`, developers and AI agents must adhere to the following rules:

---

## Architecture & Project Relationships

- **Upstream Dependency (`osm-tools`):**
  `osm-addresses` relies on the PBF download pipeline (`azure-pipelines-download-osm.yml` in `osm-tools`, pipeline definition ID 3).
- **Execution Container (`osm2parquet`):**
  DuckDB-based converter (`krizleebear/osm2parquet`) pre-packaging DuckDB CLI + `spatial` extension.
- **Data Flow:**
  1. `osm-download` pipeline downloads and caches Geofabrik `.osm.pbf` extracts.
  2. `addresses-parquet` pipeline downloads cached PBF artifacts and runs `scripts/convert.sh` from the checked-out workspace mounted directly inside the `osm2parquet` container.
  3. DuckDB extracts `addresses`, `roads`, and `entrances` into ZSTD-compressed GeoParquet files.

---

## Pipeline Architecture & Conventions

1. **Build Pipeline (`azure-pipelines.yml` / `addresses-parquet-pipeline`):**
   - 169 region matrix definitions following Geofabrik hierarchy across 7 continents.
   - Includes single-threaded `warmup` stage that verifies image availability: pulls from `ghcr.io` (primary) with 3 retries, then falls back to `mirror.gcr.io` if GHCR is unavailable. Fails explicitly if both registries fail.
   - Publishes individual per-region GeoParquet artifacts (`addresses-parquet-$(CC)-$(REGION)`) and pre-filtered address PBF artifacts (`addresses-pbf-$(CC)-$(REGION)`).

2. **Standalone Manual GitHub Release Pipeline (`azure-pipelines-release.yml` / `addresses-release-pipeline`):**
   - Releases are triggered manually on-demand (`trigger: none`).
   - Downloads latest per-region GeoParquet build artifacts and publishes individual country/region (`<CC>_<region>.addresses.parquet`) files directly as GitHub Release assets using service connection `3c34db30-d57b-42e2-a970-857bd932c6c0`.

---

## Git Workflow & Rules

1. **Azure DevOps Job Container Entrypoint Safety:**
   - Docker images intended for Azure DevOps job containers (`container: <image>`) must NOT define an exec-form `ENTRYPOINT` that exits on unknown arguments (such as `ENTRYPOINT ["/app/entrypoint.sh"]`), because Azure DevOps starts job containers with `sleep infinity`. Use `CMD ["/bin/bash"]` in the Dockerfile and invoke processing scripts explicitly in pipeline steps.
2. **Container Registry Strategy & Multi-Arch Build Safety (GHCR primary, `mirror.gcr.io` fallback)**:
   - The `osm2parquet` container image must be built as a multi-architecture image (`linux/amd64` and `linux/arm64`) and published to **both** registries on every version release.
   - Always build using `./scripts/build_docker.sh vX.Y.Z` or via the GitHub Actions CI workflow (`.github/workflows/docker-publish.yml`). Never run bare `docker build` on ARM64 macOS hosts without explicit multi-platform arguments.
   - Under the hood, builds MUST use `docker buildx build --platform linux/amd64,linux/arm64 --provenance=false`. The `--provenance=false` flag is mandatory to prevent BuildKit from generating OCI attestation manifests, which cause `unknown blob` 404 errors on `mirror.gcr.io` and manifest mismatch errors on x86-64 Azure DevOps runners.
   - The `resources.containers` image in `azure-pipelines.yml` always references `ghcr.io/krizleebear/osm2parquet:vX.Y.Z` (public, no rate limits, no auth required).
   - The GHCR package (`ghcr.io/krizleebear/osm2parquet`) must remain **public** to allow anonymous pulls from Azure DevOps hosted agents.
3. **DuckDB Script Template Substitution Invariant:**
   - DuckDB `COPY ... TO` statements require string literal paths. Do not attempt `getvariable()` inside `COPY TO`. Use `sed` token substitution (`__INPUT_PBF__`, `__OUTPUT_PARQUET__`) on SQL templates before piping into `duckdb`.
4. **Azure DevOps Parameter Condition Syntax**:
   - In Azure DevOps task/job `condition:` expressions, template parameters MUST be wrapped in `${{ eq(parameters.name, value) }}`. Raw `parameters.name` references outside `${{ }}` trigger `Unrecognized value: 'parameters'` errors.
   - In Bash scripts, handle both `"false"` and `"False"` because template expansion converts boolean false to `"False"`.
5. **Osmium Tag Pre-filtering for Runner Disk Conservation**:
   - When processing large country extracts (e.g. Germany 4.4 GB), pre-filter features using `osmium tags-filter` first, delete the raw input PBF immediately (`rm -rf osm-data-$(REGION)`), and run downstream spatial tools (DuckDB, GDAL) on the small filtered PBF to keep peak disk usage under 5 GB.
6. **Conventional Commits:**
   - Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`).
7. **English Output Standard:**
   - Log outputs, diagnostic error messages, and pipeline notices must be written strictly in clear English.
8. **Downstream Job Dependency Safety (`condition: succeeded()`):**
   - Downstream stages or jobs that aggregate artifacts from upstream parallel matrix jobs MUST use `condition: succeeded()`. Never use `condition: always()` on release or bundling steps, as cancellation or upstream failure would trigger incomplete artifact processing.
9. **Evidence-Based Issue Analysis & Remote DuckDB Diagnostics:**
   - Never make assumptions about dataset contents based solely on commit logs or code inspections. Always gather concrete evidence by directly querying release artifacts using DuckDB with `httpfs` (`duckdb -c "INSTALL httpfs; LOAD httpfs; SELECT ... FROM 'https://github.com/.../releases/download/.../....parquet'"`). Include reproducible diagnostic SQL queries in bug reports and responses.
10. **Explanation Preceding Git Actions Invariant (Explain First, Commit Second):**
    - The agent must always first output a clear, comprehensive explanation of the diagnosis, the rationale, and the exact changes in the visible response text before requesting permission or attempting to execute `git commit`, `git push`, or pipeline triggers. Never trigger permission prompts for Git actions without the user having seen the complete explanatory context first.
11. **Parquet Provenance & License Metadata Invariant:**
    - All GeoParquet files produced by `osm2parquet` (`export_addresses.sql`) MUST embed standard provenance, copyright, and licensing metadata in the Parquet file footer via DuckDB's `KV_METADATA` option.
    - Required metadata keys:
      - `source`: `OpenStreetMap`
      - `origin`: `OpenStreetMap (https://www.openstreetmap.org)`
      - `dataset`: `OpenStreetMap Addresses`
      - `attribution`: `© OpenStreetMap contributors`
      - `attribution_url`: `https://www.openstreetmap.org/copyright`
      - `license`: `ODbL-1.0 (https://opendatacommons.org/licenses/odbl/)`
      - `license_url`: `https://opendatacommons.org/licenses/odbl/`
      - `copyright`: `Data © OpenStreetMap contributors, licensed under Open Data Commons Open Database License 1.0 (ODbL)`
      - `schema`: `https://github.com/krizleebear/osm-addresses`
      - `schema_url`: `https://github.com/krizleebear/osm-addresses`
      - `compiler`: `osm-addresses (https://github.com/krizleebear/osm-addresses)`
      - `country_code`: 2-letter ISO code or territory identifier (e.g. `DE`, `US`)
      - `exported_at`: ISO-8601 UTC timestamp (e.g. `YYYY-MM-DDTHH:MM:SSZ`)



