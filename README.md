# portolan-catalog-utrecht

This repository contains a Portolan catalog with geodata for the municipality
of Utrecht, and the scripts used to generate and maintain it.

### Usage

```bash
./scripts/fetch.sh
```

Requirements: `git`, `python3` (with the `venv` module), `tippecanoe` (for
PMTiles generation) and a working `duckdb` CLI (see
`tools/shrink_parquet_files.sh` for installation instructions).

## scripts/fetch.sh

This script rebuilds the full catalog from the ArcGIS Online services of
Utrecht https://services-eu1.arcgis.com/SMnoOtmU2UWf0vRp/ArcGIS/rest/services, using [portolan-cli](https://github.com/portolan-sdi/portolan-cli).

The script goes through the following steps:

1. **Clone**: clones `portolan-cli` into a temporary directory `portolan-cli/`
   next to this script.
2. **Branch**: checks out branch `release/v1.0.0b0`.
3. **Python environment**: creates a Python virtual environment (`.venv`) and
   activates it, so the installation stays isolated from the system.
4. **Dependencies**: installs the Python dependencies of `portolan-cli` with
   `pip install -e .`.
5. **duckdb**: force-(re)installs version `duckdb==1.5.5`, regardless of the
   version pulled in as a dependency.
6. **Extraction**: runs
   `portolan extract arcgis https://services-eu1.arcgis.com/SMnoOtmU2UWf0vRp/ArcGIS/rest/services <absolute-path-to-catalog> --license CC-BY-4.0 --auto`,
   which fetches the data and writes it as a Portolan catalog to the
   `catalog/` directory in the root of this repository. Existing catalog data
   is overwritten in the process. The `--auto` flag skips the interactive
   "Continue?" confirmation prompt, keeping the run non-interactive/silent.
   An absolute path is passed for the output directory because portolan-cli's
   `validate_safe_path` check rejects any path containing `..` as a
   directory-traversal attempt (a relative `../catalog` fails with
   `Invalid output path (directory traversal detected)`). If one or more
   layers fail (e.g. a source service returns malformed GeoJSON), the script
   does not abort: it logs a warning and continues with the layers that were
   extracted successfully.
7. **PMTiles per service**: runs `portolan add <service> --pmtiles` for every
   service (collection directory) found in the catalog. This generates a
   PMTiles derivative per service together with its required style asset, so
   every service renders with correct styling. Requires `tippecanoe` on PATH.
   A failure for one service is logged as a warning and does not stop the
   remaining services from being processed.
8. **Shrinking**: runs `tools/shrink_parquet_files.sh` on the generated
   catalog data, to shrink parquet files larger than the size limit by
   simplifying geometries with DuckDB (`ST_Simplify`).
9. **Cleanup**: removes the cloned `portolan-cli` code and the corresponding
   Python virtual environment again, so only the generated catalog data in
   `catalog/` remains. Cleanup always runs, even if a previous step logged
   warnings.

If any layer or service failed along the way, the script prints a summary
warning and exits with a non-zero status **after** all steps (including
cleanup) have completed, so a partial-but-usable catalog is never discarded.

### How the ArcGIS extraction fetches data (GeoJSON paging)

`portolan extract arcgis` (step 6) does not implement the actual feature
download itself: it discovers services and layers via the ArcGIS REST API's
own JSON metadata (e.g. `.../FeatureServer?f=json`), then delegates each
layer's data download to the
[`geoparquet-io`](https://github.com/geoparquet/geoparquet-io) library
(`geoparquet_io/core/arcgis.py`). That library is what prints the extraction
progress lines seen in the console and is the source of the layer failures
documented below.

For every layer, `geoparquet-io`:

1. Queries the layer's ArcGIS REST `/query` endpoint page by page, using:
   - `f=geojson` — request each page as GeoJSON (per RFC 7946 this is always
     WGS84 / EPSG:4326), unless a native CRS is requested, in which case it
     switches to EsriJSON (`f=json`) with an explicit `outSR`.
   - `resultOffset` / `resultRecordCount` — the page offset and page size for
     pagination through the layer's features.
   - `where`, `outFields`, and (when a bbox filter is set)
     `geometry`/`geometryType`/`spatialRel`/`inSR` — server-side filters and
     column selection.
   This is exactly what produces the `Fetching features X-Y of Z...`
   progress lines: one line per page requested from the service.
2. Writes each downloaded GeoJSON page verbatim to a temporary file
   (`/tmp/arcgis_page_<uuid>.geojson`) — this is the `Streaming features to
   temp file...` progress line — and reads it back with DuckDB's `spatial`
   extension:
   ```sql
   SELECT ST_AsWKB(geom) as geometry, * EXCLUDE (geom, OGC_FID)
   FROM ST_Read('<temp file>')
   ```
   DuckDB's `ST_Read()` (backed by GDAL) does the actual GeoJSON parsing and
   hands back an Arrow table with a WKB geometry column; the temp file is
   deleted immediately after.
3. Explicitly excludes the `OGC_FID` column that `ST_Read()` auto-generates
   for GeoJSON — which is exactly the mechanism that breaks in the
   `duplicate column name "ogc_fid"` failure documented below: when a
   layer's own attributes already contain a field literally named `ogc_fid`,
   `ST_Read()` cannot even build its result set, so the query fails before
   the `EXCLUDE` clause ever gets a chance to run.
4. Falls back to progressively smaller page sizes
   (`1000, 500, 100, 50, 10, 1` features per page) if GDAL can't parse a page
   because a single feature is too large/complex, and retries with the
   smaller batch size.
5. Accumulates all pages for the layer, then hands the layer off to
   `portolan-cli`, which writes it out as one GeoParquet file — optionally
   Hilbert-sorted — at `catalog/<service>/<layer>/<layer>.parquet`.

### Known upstream layer failures

Individual ArcGIS layers can fail during extraction (step 6) due to data
quirks in the source services rather than a problem with this script or
`fetch.sh`'s error handling. Failures seen so far:

- **`IO Error: Failed to read GeoJSON data`** — the source service returned
  malformed or unreadable GeoJSON for that layer.
- **`Binder Error: table "st_read" has duplicate column name "ogc_fid"`** —
  the layer's own attributes already contain a field that collides with the
  `ogc_fid` column DuckDB's `ST_Read` (GDAL) auto-generates, so the read
  fails with a duplicate-column error. Seen for example on the
  `UTWV_verwachting_landschap` layer.

  Reproduce it with a minimal GeoJSON file whose properties already contain a
  field literally named `ogc_fid`:

  ```bash
  cat > duplicate_ogc_fid.geojson << 'EOF'
  {
    "type": "FeatureCollection",
    "features": [
      {
        "type": "Feature",
        "properties": { "ogc_fid": 1, "name": "Test feature" },
        "geometry": { "type": "Point", "coordinates": [5.12, 52.09] }
      }
    ]
  }
  EOF

  # GDAL's ogrinfo reads it fine on its own — the GeoJSON driver exposes no
  # dedicated FID column, so "ogc_fid" is just a normal field here:
  ogrinfo -al -so duplicate_ogc_fid.geojson

  # DuckDB's spatial extension is what actually reproduces the error:
  # ST_Read() adds its own "ogc_fid" pseudo feature-id column on top of the
  # attribute fields it reads through GDAL, so it collides with the source
  # attribute of the same name.
  duckdb -c "
      INSTALL spatial; LOAD spatial;
      SELECT * FROM ST_Read('duplicate_ogc_fid.geojson');
  "
  ```

  The `duckdb` command fails with the exact same error seen in the
  extraction log:

  ```text
  Binder Error: table "st_read" has duplicate column name "ogc_fid"
  ```

These are upstream data issues in the ArcGIS services, not bugs in
`fetch.sh`; the affected layer is skipped, a warning is logged, and the rest
of the catalog is still extracted normally.

## tools/shrink_parquet_files.sh

Scans a directory of `.parquet` files and shrinks files larger than the
configured limit (default 25 MB) by progressively simplifying the geometry
with DuckDB's `spatial` extension, until the file drops below the limit. See
the script's header for details and usage.
