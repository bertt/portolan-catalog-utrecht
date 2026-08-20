#!/usr/bin/env bash
#
# shrink_parquet_files.sh
#
# Scans an output directory for .parquet files and shrinks any file larger
# than MAX_SIZE_MB by progressively simplifying its geometry with DuckDB's
# spatial extension (ST_Simplify), until the file drops below the limit.
#
# Requirements:
#   - duckdb CLI (https://duckdb.org). Install with:
#       curl https://install.duckdb.org | sh
#     The "spatial" extension is installed automatically on first run.
#
# Usage:
#   ./shrink_parquet_files.sh [output-dir] [max-mb]
#
#   output-dir  Directory containing (subdirectories of) .parquet files.
#               Default: current directory.
#   max-mb      Maximum file size in MB. Default: 25.
#
# Example:
#   ./shrink_parquet_files.sh /data/portolan-cli/output 25

set -euo pipefail

OUTPUT_DIR="${1:-.}"
MAX_SIZE_MB="${2:-25}"
MAX_SIZE_BYTES=$((MAX_SIZE_MB * 1024 * 1024))

# Starting value and growth factor for the simplify tolerance. The tolerance
# is expressed in the units of the layer's CRS (for EPSG:4326 / OGC:CRS84
# that's degrees; 0.00001 degrees is roughly 1 meter).
INITIAL_TOLERANCE=0.00001
GROWTH_FACTOR=1.6
MAX_ITER=25

if ! command -v duckdb >/dev/null 2>&1; then
    echo "Error: duckdb not found. Install it with: curl https://install.duckdb.org | sh" >&2
    exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "Error: directory '$OUTPUT_DIR' does not exist." >&2
    exit 1
fi

# Make sure the spatial extension is available (cached locally after the
# first install, so this is a no-op on subsequent runs).
duckdb -c "INSTALL spatial;" >/dev/null 2>&1 || true

human_mb() {
    awk -v b="$1" 'BEGIN{printf "%.2f", b/1024/1024}'
}

# Escapes single quotes for safe embedding in SQL string literals.
sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# Collects "path|before_bytes|after_bytes" for the final summary.
CHANGED_FILES=()

process_file() {
    local FILE="$1"
    local SIZE
    SIZE=$(stat -c%s "$FILE")

    if (( SIZE <= MAX_SIZE_BYTES )); then
        echo "OK   ($(human_mb "$SIZE") MB): $FILE"
        return 0
    fi

    echo "TOO LARGE ($(human_mb "$SIZE") MB, limit ${MAX_SIZE_MB}MB): $FILE"

    local ESCAPED_FILE
    ESCAPED_FILE=$(sql_escape "$FILE")

    # Find the geometry column (if any) so we know which one to simplify.
    local GEOM_COL
    GEOM_COL=$(duckdb -csv -noheader -c "
        LOAD spatial;
        SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet('${ESCAPED_FILE}'))
        WHERE column_type ILIKE 'GEOMETRY%'
        LIMIT 1;
    " 2>/tmp/shrink_parquet_duckdb.err)

    if [[ -z "$GEOM_COL" ]]; then
        echo "  skipping: no geometry column found, cannot shrink without data loss."
        return 0
    fi

    local DIR BASENAME TMP_FILE ESCAPED_TMP
    DIR="$(dirname "$FILE")"
    BASENAME="$(basename "$FILE")"
    TMP_FILE="${DIR}/.${BASENAME}.tmp"
    ESCAPED_TMP=$(sql_escape "$TMP_FILE")

    local TOLERANCE="$INITIAL_TOLERANCE"
    local ITER=0
    local NEW_SIZE=0
    local SUCCESS=0

    while (( ITER < MAX_ITER )); do
        rm -f "$TMP_FILE"

        if ! duckdb -c "
            LOAD spatial;
            COPY (
                SELECT * REPLACE (ST_Simplify(\"${GEOM_COL}\", ${TOLERANCE}) AS \"${GEOM_COL}\")
                FROM read_parquet('${ESCAPED_FILE}')
            ) TO '${ESCAPED_TMP}' (FORMAT PARQUET, COMPRESSION ZSTD);
        " >/tmp/shrink_parquet_duckdb.err 2>&1; then
            echo "  duckdb error (see /tmp/shrink_parquet_duckdb.err), skipped."
            rm -f "$TMP_FILE"
            return 1
        fi

        NEW_SIZE=$(stat -c%s "$TMP_FILE")
        echo "  attempt $((ITER + 1)): tolerance=${TOLERANCE} -> $(human_mb "$NEW_SIZE") MB"

        if (( NEW_SIZE <= MAX_SIZE_BYTES )); then
            SUCCESS=1
            break
        fi

        TOLERANCE=$(awk -v t="$TOLERANCE" -v g="$GROWTH_FACTOR" 'BEGIN{printf "%.8f", t*g}')
        ITER=$((ITER + 1))
    done

    if (( SUCCESS == 1 )); then
        mv "$TMP_FILE" "$FILE"
        echo "  DONE: $FILE shrunk to $(human_mb "$NEW_SIZE") MB"
        CHANGED_FILES+=("${FILE}|${SIZE}|${NEW_SIZE}")
    else
        echo "  WARNING: could not get below ${MAX_SIZE_MB}MB after ${MAX_ITER} attempts: $FILE"
        rm -f "$TMP_FILE"
        return 1
    fi
}

FAILED=0
while IFS= read -r -d '' FILE; do
    if ! process_file "$FILE"; then
        FAILED=$((FAILED + 1))
    fi
done < <(find "$OUTPUT_DIR" -type f -name "*.parquet" -print0)

echo ""
echo "===================== Summary ====================="
if (( ${#CHANGED_FILES[@]} == 0 )); then
    echo "No files were modified."
else
    printf "%-70s %10s %10s %8s\n" "File" "Before" "After" "Reduced"
    for ENTRY in "${CHANGED_FILES[@]}"; do
        IFS='|' read -r ENTRY_FILE ENTRY_BEFORE ENTRY_AFTER <<< "$ENTRY"
        PCT=$(awk -v b="$ENTRY_BEFORE" -v a="$ENTRY_AFTER" 'BEGIN{printf "%.1f", (1 - a/b) * 100}')
        printf "%-70s %8sMB %8sMB %7s%%\n" \
            "$ENTRY_FILE" "$(human_mb "$ENTRY_BEFORE")" "$(human_mb "$ENTRY_AFTER")" "$PCT"
    done
    echo "-----------------------------------------------------"
    echo "Total files modified: ${#CHANGED_FILES[@]}"
fi
echo "====================================================="

if (( FAILED > 0 )); then
    echo ""
    echo "Done, but $FAILED file(s) could not be (fully) shrunk."
    exit 1
fi

echo ""
echo "Done: all .parquet files are under ${MAX_SIZE_MB}MB."
