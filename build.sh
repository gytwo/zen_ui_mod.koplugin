#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
PLUGIN_DIR_NAME="$(basename "$REPO_ROOT")"

if [[ "$PLUGIN_DIR_NAME" != *.koplugin ]]; then
  echo "Error: repository folder name must end with .koplugin (found: $PLUGIN_DIR_NAME)" >&2
  exit 1
fi

for cmd in rsync zip mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

DIST_DIR="$REPO_ROOT/dist"
OUT_ZIP="$DIST_DIR/${PLUGIN_DIR_NAME}.zip"
STAGE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/koplugin-build.XXXXXX")"
STAGE_DIR="$STAGE_PARENT/$PLUGIN_DIR_NAME"

cleanup() {
  rm -rf "$STAGE_PARENT"
}
trap cleanup EXIT

# Start each build from a clean output directory.
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$STAGE_DIR"

# Stage only distributable plugin files.
rsync -a \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude '.vscode/' \
  --exclude 'dist/' \
  --exclude '.DS_Store' \
  --exclude '.gitignore' \
  --exclude '*.zip' \
  --exclude '*.sh' \
  --exclude '*.md' \
  --exclude 'images/' \
  "$REPO_ROOT/" "$STAGE_DIR/"

rm -f "$OUT_ZIP"
(
  cd "$STAGE_PARENT"
  zip -rq "$OUT_ZIP" "$PLUGIN_DIR_NAME"
)

echo "Created KOReader plugin zip: $OUT_ZIP"
