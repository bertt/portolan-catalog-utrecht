#!/usr/bin/env bash
#
# fetch.sh
#
# Fetches the portolan-cli tool, builds an isolated Python environment for
# it, uses the tool to extract the Utrecht ArcGIS Online catalog into the
# catalog/ directory of this repository, and then shrinks the generated
# parquet files. The cloned code and Python environment (portolan-cli/) are
# left in place after the script finishes, so subsequent runs can reuse the
# existing virtual environment instead of recreating it from scratch. The
# portolan-cli/ directory is listed in .gitignore, so it is never committed.
#
# Steps:
#   1. Clone https://github.com/portolan-sdi/portolan-cli into a temporary
#      directory (skipped if that directory, and its virtual environment,
#      already exist from a previous run).
#   2. Checkout branch release/v1.0.0b0 (skipped when reusing an existing
#      clone/venv).
#   3. Create a Python virtual environment and activate it (skipped when
#      reusing an existing venv; it is only activated).
#   4. Install the Python dependencies of portolan-cli with pip, including the
#      `pmtiles` extra (`portolan-cli[pmtiles]`), which is required for step 7
#      (skipped when reusing an existing venv).
#   5. Force-install duckdb==1.5.5 (skipped when reusing an existing venv).
#   6. Run `portolan extract arcgis ... <absolute catalog path> --license CC-BY-4.0 --auto`
#      (existing catalog data is overwritten; --auto skips the interactive
#      "Continue?" confirmation prompt so the run stays non-interactive; an
#      absolute path is required because portolan-cli rejects ".." in output
#      paths as a directory-traversal attempt). Individual layers can fail
#      (e.g. malformed GeoJSON from the source service); such failures do not
#      abort the whole script, they are reported as warnings instead.
#   7. Check that the `pmtiles` extra (gpio-pmtiles, pmtiles) is installed,
#      then run `portolan add --pmtiles` for every service (collection
#      directory) in the catalog. This generates a PMTiles derivative per
#      service together with its required style asset, so each service
#      renders with correct styling. Requires tippecanoe on PATH. A failure
#      for one service is reported as a warning; the remaining services are
#      still processed.
#   8. Run tools/shrink_parquet_files.sh on the generated catalog data.
#
# If any layer or service failed along the way, the script prints a summary
# and exits with a non-zero status at the very end.
#
# Usage:
#   ./scripts/fetch.sh

set -euo pipefail

REPO_URL="https://github.com/portolan-sdi/portolan-cli"
BRANCH="release/v1.0.0b0"
ARCGIS_URL="https://services-eu1.arcgis.com/SMnoOtmU2UWf0vRp/ArcGIS/rest/services"
LICENSE="CC-BY-4.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLONE_DIR="${REPO_ROOT}/portolan-cli"
VENV_DIR="${CLONE_DIR}/.venv"
CATALOG_DIR="${REPO_ROOT}/catalog"
SHRINK_SCRIPT="${REPO_ROOT}/tools/shrink_parquet_files.sh"

# Tracks whether any (per-layer or per-service) failure occurred, so the
# script can still finish all steps (PMTiles, shrinking, cleanup) and only
# report/exit non-zero at the very end instead of aborting midway.
HAD_FAILURES=0

if [[ -d "${VENV_DIR}" ]]; then
    echo "==> 1-5/8 Reusing existing clone and virtual environment in ${CLONE_DIR}"
    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"
else
    echo "==> 1/8 Cloning ${REPO_URL} into ${CLONE_DIR}"
    rm -rf "${CLONE_DIR}"
    git clone "${REPO_URL}" "${CLONE_DIR}"

    echo "==> 2/8 Checking out branch ${BRANCH}"
    git -C "${CLONE_DIR}" checkout "${BRANCH}"

    echo "==> 3/8 Creating and activating Python virtual environment"
    python3 -m venv "${VENV_DIR}"
    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"
    pip install --upgrade pip

    echo "==> 4/8 Installing Python dependencies with pip"
    # The [pmtiles] extra pulls in gpio-pmtiles (and the pmtiles package), which
    # are required by the "portolan add --pmtiles" step below. Without it, that
    # step fails with "gpio-pmtiles package not installed. Install with: pip
    # install portolan-cli[pmtiles]".
    pip install -e "${CLONE_DIR}[pmtiles]"

    echo "==> 5/8 Force-installing duckdb==1.5.5"
    pip install --force-reinstall duckdb==1.5.5
fi

echo "==> 6/8 Extracting catalog data with portolan-cli"
if [[ -d "${CATALOG_DIR}" ]]; then
    echo "    Existing catalog data found, overwriting: ${CATALOG_DIR}"
    rm -rf "${CATALOG_DIR}"
fi
EXTRACT_STATUS=0
(
    cd "${CLONE_DIR}"
    # Note: portolan-cli's validate_safe_path rejects any output path
    # containing ".." as a directory-traversal attempt, so an absolute path
    # must be passed here instead of the relative "../catalog".
    portolan extract arcgis "${ARCGIS_URL}" "${CATALOG_DIR}" --license "${LICENSE}" --auto
) || EXTRACT_STATUS=$?
if (( EXTRACT_STATUS != 0 )); then
    HAD_FAILURES=1
    echo "    WARNING: portolan extract reported one or more layer failures (exit code ${EXTRACT_STATUS})."
    echo "    Continuing with the layers that were extracted successfully."
fi

echo "==> 7/8 Generating PMTiles per service"
if ! python3 -c "import gpio_pmtiles, pmtiles" >/dev/null 2>&1; then
    echo "    ERROR: the 'pmtiles' extra of portolan-cli is not installed." >&2
    echo "    Install it with: pip install portolan-cli[pmtiles]" >&2
    exit 1
fi
(
    cd "${CATALOG_DIR}"
    for SERVICE_DIR in */; do
        SERVICE_NAME="${SERVICE_DIR%/}"
        [[ "${SERVICE_NAME}" == .* ]] && continue
        echo "    portolan add ${SERVICE_NAME} --pmtiles"
        if ! portolan add "${SERVICE_NAME}" --pmtiles; then
            echo "    WARNING: PMTiles generation failed for service '${SERVICE_NAME}', continuing with remaining services." >&2
            touch "${REPO_ROOT}/.fetch_pmtiles_failed"
        fi
    done
)
if [[ -f "${REPO_ROOT}/.fetch_pmtiles_failed" ]]; then
    HAD_FAILURES=1
    rm -f "${REPO_ROOT}/.fetch_pmtiles_failed"
fi

echo "==> 8/8 Shrinking parquet files"
"${SHRINK_SCRIPT}" "${CATALOG_DIR}"

echo "==> Done"
echo "Catalog data is located in: ${CATALOG_DIR}"

if (( HAD_FAILURES != 0 )); then
    echo ""
    echo "Completed with one or more warnings (see above); check the catalog data before publishing."
    exit 1
fi
