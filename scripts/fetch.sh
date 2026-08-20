#!/usr/bin/env bash
#
# fetch.sh
#
# Fetches the portolan-cli tool, builds an isolated Python environment for
# it, uses the tool to extract the Utrecht ArcGIS Online catalog into the
# catalog/ directory of this repository, and then shrinks the generated
# parquet files. The cloned code and the Python environment are cleaned up
# again at the end.
#
# Steps:
#   1. Clone https://github.com/portolan-sdi/portolan-cli into a temporary directory.
#   2. Checkout branch release/v1.0.0b0.
#   3. Create a Python virtual environment and activate it.
#   4. Install the Python dependencies of portolan-cli with pip.
#   5. Force-install duckdb==1.5.5.
#   6. Run `portolan extract arcgis ... <absolute catalog path> --license CC-BY-4.0 --auto`
#      (existing catalog data is overwritten; --auto skips the interactive
#      "Continue?" confirmation prompt so the run stays non-interactive; an
#      absolute path is required because portolan-cli rejects ".." in output
#      paths as a directory-traversal attempt). Individual layers can fail
#      (e.g. malformed GeoJSON from the source service); such failures do not
#      abort the whole script, they are reported as warnings instead.
#   7. Run `portolan add --pmtiles` for every service (collection directory) in
#      the catalog. This generates a PMTiles derivative per service together
#      with its required style asset, so each service renders with correct
#      styling. Requires tippecanoe on PATH. A failure for one service is
#      reported as a warning; the remaining services are still processed.
#   8. Run tools/shrink_parquet_files.sh on the generated catalog data.
#   9. Clean up the cloned portolan-cli code and the virtual environment.
#
# If any layer or service failed along the way, the script prints a summary
# and exits with a non-zero status at the very end, after all steps
# (including cleanup) have completed.
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

cleanup() {
    echo ""
    echo "Cleaning up: removing cloned code and Python environment..."
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        deactivate 2>/dev/null || true
    fi
    rm -rf "${CLONE_DIR}"
}
trap cleanup EXIT

echo "==> 1/9 Cloning ${REPO_URL} into ${CLONE_DIR}"
rm -rf "${CLONE_DIR}"
git clone "${REPO_URL}" "${CLONE_DIR}"

echo "==> 2/9 Checking out branch ${BRANCH}"
git -C "${CLONE_DIR}" checkout "${BRANCH}"

echo "==> 3/9 Creating and activating Python virtual environment"
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip

echo "==> 4/9 Installing Python dependencies with pip"
pip install -e "${CLONE_DIR}"

echo "==> 5/9 Force-installing duckdb==1.5.5"
pip install --force-reinstall duckdb==1.5.5

echo "==> 6/9 Extracting catalog data with portolan-cli"
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

echo "==> 7/9 Generating PMTiles per service"
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

echo "==> 8/9 Shrinking parquet files"
"${SHRINK_SCRIPT}" "${CATALOG_DIR}"

echo "==> 9/9 Done"
echo "Catalog data is located in: ${CATALOG_DIR}"

if (( HAD_FAILURES != 0 )); then
    echo ""
    echo "Completed with one or more warnings (see above); check the catalog data before publishing."
    exit 1
fi
