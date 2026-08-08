#!/bin/bash
#
# Step 4: Aggregate results
# Combines individual doc review results into a summary
#
# Usage: 04-aggregate.sh RESULTS_DIR DOCS_JSON
# Output: JSON summary to stdout
#

set -euo pipefail

RESULTS_DIR="${1:-}"
DOCS_JSON="${2:-}"

if [[ -z "$RESULTS_DIR" ]] || [[ -z "$DOCS_JSON" ]]; then
  echo "Usage: 04-aggregate.sh RESULTS_DIR DOCS_JSON" >&2
  exit 1
fi

# Read docs data
TOTAL_DOCS=$(jq -r '.docs | length' "$DOCS_JSON")

# Aggregate results
DOCS_CURRENT=0
DOCS_STALE=0
DOCS_ERROR=0
TOTAL_ISSUES=0

# Build results array
RESULTS_JSON="["
first=true

for result_file in "$RESULTS_DIR"/*.json; do
  [[ -f "$result_file" ]] || continue

  doc_path=$(jq -r '.doc_path' "$result_file" 2>/dev/null || basename "$result_file" .json | tr '-' '/')
  status=$(jq -r '.status // "ERROR"' "$result_file" 2>/dev/null || echo "ERROR")
  reason=$(jq -r '.reason // "-"' "$result_file" 2>/dev/null || echo "-")
  issues_count=$(jq -r '.issues | length' "$result_file" 2>/dev/null || echo "0")

  TOTAL_ISSUES=$((TOTAL_ISSUES + issues_count))

  case "$status" in
    CURRENT)
      DOCS_CURRENT=$((DOCS_CURRENT + 1))
      ;;
    STALE)
      DOCS_STALE=$((DOCS_STALE + 1))
      ;;
    *)
      DOCS_ERROR=$((DOCS_ERROR + 1))
      ;;
  esac

  # Add to results array
  if [[ "$first" == "true" ]]; then
    first=false
  else
    RESULTS_JSON+=","
  fi

  RESULTS_JSON+=$(cat "$result_file")
done

RESULTS_JSON+="]"

# Determine verdict
if [[ $DOCS_ERROR -gt 0 ]]; then
  VERDICT="ERROR"
  VERDICT_REASON="$DOCS_ERROR document(s) failed to review"
elif [[ $DOCS_STALE -gt 0 ]]; then
  VERDICT="STALE"
  VERDICT_REASON="$DOCS_STALE documentation file(s) may need updating ($TOTAL_ISSUES issue(s) found)"
else
  VERDICT="CURRENT"
  VERDICT_REASON="All $DOCS_CURRENT documentation files are current"
fi

# Output summary
cat << EOF
{
  "verdict": "$VERDICT",
  "verdict_reason": "$VERDICT_REASON",
  "stats": {
    "total_docs": $TOTAL_DOCS,
    "docs_current": $DOCS_CURRENT,
    "docs_stale": $DOCS_STALE,
    "docs_error": $DOCS_ERROR,
    "total_issues": $TOTAL_ISSUES
  },
  "results": $RESULTS_JSON
}
EOF
