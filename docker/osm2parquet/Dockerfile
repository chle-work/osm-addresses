FROM debian:bookworm-slim

ARG TARGETARCH

# Install system dependencies required by GDAL OSM driver and DuckDB spatial extension.
# All packages are pre-installed here — no runtime apt-get allowed per AGENTS.md rule 7.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    ca-certificates \
    libgdal-dev \
    osmium-tool \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install DuckDB CLI — pinned version for reproducibility
ARG DUCKDB_VERSION=v1.5.5
RUN curl -fsSL \
    "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${TARGETARCH}.zip" \
    -o /tmp/duckdb.zip \
    && unzip /tmp/duckdb.zip -d /usr/local/bin \
    && rm /tmp/duckdb.zip \
    && chmod +x /usr/local/bin/duckdb

# Create /app first, then point HOME there so DuckDB installs extensions into
# /app/.duckdb/ — a path the non-root runtime user can access.
WORKDIR /app
ENV HOME=/app

# Pre-install and cache DuckDB spatial extension at build time.
# This avoids any runtime network access inside Azure DevOps jobs.
RUN duckdb -c "INSTALL spatial;"

# Grant 777 permissions to /app so Azure DevOps unprivileged runner user
# (vsts_azpcontainer UID 1001) can read pre-installed spatial extension at /app/.duckdb/
RUN chmod -R 777 /app

LABEL org.opencontainers.image.source="https://github.com/krizleebear/osm-addresses"
LABEL org.opencontainers.image.description="DuckDB spatial converter for OSM GeoParquet exports"
LABEL org.opencontainers.image.url="https://github.com/krizleebear/osm-addresses/blob/master/docker/osm2parquet/Dockerfile"

CMD ["/bin/bash"]

