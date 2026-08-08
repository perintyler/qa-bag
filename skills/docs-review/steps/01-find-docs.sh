#!/bin/bash
#
# Step 1: Find documentation files
# Scans repo for markdown files and other documentation
#
# Usage: 01-find-docs.sh [--filter=PATTERN] REPO_ROOT
# Output: JSON to stdout
#

set -euo pipefail

FILTER=""
REPO_ROOT=""

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --filter=*)
      FILTER="${1#*=}"
      shift
      ;;
    *)
      REPO_ROOT="$1"
      shift
      ;;
  esac
done

if [[ -z "$REPO_ROOT" ]]; then
  echo "Usage: 01-find-docs.sh [--filter=PATTERN] REPO_ROOT" >&2
  exit 1
fi

cd "$REPO_ROOT"

# Find all markdown files, excluding node_modules, .git, etc.
docs=()

while IFS= read -r -d '' file; do
  # Get relative path
  rel_path="${file#./}"

  # Skip hidden directories and common non-doc locations
  [[ "$rel_path" == .* ]] && continue
  [[ "$rel_path" == *node_modules* ]] && continue
  [[ "$rel_path" == *dist/* ]] && continue
  [[ "$rel_path" == *build/* ]] && continue
  [[ "$rel_path" == *.reports/* ]] && continue
  [[ "$rel_path" == */.swe/* ]] && continue

  # Apply filter if set
  if [[ -n "$FILTER" ]] && [[ ! "$rel_path" == *"$FILTER"* ]]; then
    continue
  fi

  docs+=("$rel_path")
done < <(find . -name "*.md" -type f -print0 2>/dev/null)

# Build JSON output
echo "{"
echo "  \"repo_root\": \"$REPO_ROOT\","
echo "  \"filter\": \"$FILTER\","
echo "  \"docs\": ["

first=true
for doc in "${docs[@]}"; do
  # Determine related directories (where code that this doc describes lives)
  related_dirs=""
  doc_dir=$(dirname "$doc")

  # If doc is in root, it relates to the whole repo
  if [[ "$doc_dir" == "." ]]; then
    related_dirs="."
  else
    # Doc relates to its parent directory
    related_dirs="$doc_dir"
  fi

  # Special handling for component-level docs
  # e.g., mcp/datadog/README.md relates to mcp/datadog/

  if [[ "$first" == "true" ]]; then
    first=false
  else
    echo ","
  fi

  # Determine doc type
  doc_type="other"
  basename_lower=$(basename "$doc" | tr '[:upper:]' '[:lower:]')
  case "$basename_lower" in
    readme.md) doc_type="readme" ;;
    claude.md) doc_type="claude" ;;
    qa.md)     doc_type="qa" ;;
    *.md)
      if [[ "$doc_dir" == *docs* ]]; then
        doc_type="docs"
      fi
      ;;
  esac

  printf '    {"path": "%s", "type": "%s", "related_dirs": ["%s"]}' "$doc" "$doc_type" "$related_dirs"
done

echo ""
echo "  ]"
echo "}"
