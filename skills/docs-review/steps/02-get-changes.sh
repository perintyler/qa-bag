#!/bin/bash
#
# Step 2: Get git changes since last review
# Returns changed files and affected components
#
# Usage: 02-get-changes.sh REPO_ROOT BASE_COMMIT
# Output: JSON to stdout
#

set -euo pipefail

REPO_ROOT="${1:-}"
BASE_COMMIT="${2:-}"

if [[ -z "$REPO_ROOT" ]] || [[ -z "$BASE_COMMIT" ]]; then
  echo "Usage: 02-get-changes.sh REPO_ROOT BASE_COMMIT" >&2
  exit 1
fi

cd "$REPO_ROOT"

HEAD_COMMIT=$(git rev-parse HEAD)

# Get list of changed files
changed_files=()
while IFS= read -r file; do
  [[ -n "$file" ]] && changed_files+=("$file")
done < <(git diff --name-only "$BASE_COMMIT" HEAD 2>/dev/null || true)

# Identify affected components (top-level directories)
declare -A components
for file in "${changed_files[@]}"; do
  # Get first directory component
  component=$(echo "$file" | cut -d'/' -f1-2 | head -1)
  if [[ -n "$component" ]]; then
    components["$component"]=1
  fi
done

# Get base commit date
BASE_DATE=$(git show -s --format=%ci "$BASE_COMMIT" 2>/dev/null | cut -d' ' -f1 || echo "unknown")

# Build JSON output
echo "{"
echo "  \"base_commit\": \"$BASE_COMMIT\","
echo "  \"base_date\": \"$BASE_DATE\","
echo "  \"head_commit\": \"$HEAD_COMMIT\","
echo "  \"files_changed\": ${#changed_files[@]},"

# Components array
echo "  \"components\": ["
first=true
for comp in "${!components[@]}"; do
  if [[ "$first" == "true" ]]; then
    first=false
    printf '    "%s"' "$comp"
  else
    printf ',\n    "%s"' "$comp"
  fi
done
echo ""
echo "  ],"

# Changed files array
echo "  \"files\": ["
first=true
for file in "${changed_files[@]}"; do
  # Get change type (A=added, M=modified, D=deleted)
  change_type=$(git diff --name-status "$BASE_COMMIT" HEAD 2>/dev/null | grep -E "^[AMD]\s+$file$" | cut -f1 || echo "M")

  if [[ "$first" == "true" ]]; then
    first=false
  else
    echo ","
  fi

  # Get file extension for categorization
  ext="${file##*.}"
  category="other"
  case "$ext" in
    ts|tsx|js|jsx) category="code" ;;
    md)            category="docs" ;;
    json)          category="config" ;;
    sh)            category="script" ;;
    css|scss)      category="style" ;;
  esac

  printf '    {"path": "%s", "type": "%s", "category": "%s"}' "$file" "$change_type" "$category"
done
echo ""
echo "  ]"
echo "}"
