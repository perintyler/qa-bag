#!/bin/bash
#
# Step 5: Generate markdown report
# Converts aggregated JSON into a readable report
#
# Usage: 05-report.sh SUMMARY_JSON REPORT_ID CHANGES_JSON OUTPUT_FILE
# Output: Markdown report written to OUTPUT_FILE
#

set -euo pipefail

SUMMARY_JSON="${1:-}"
REPORT_ID="${2:-}"
CHANGES_JSON="${3:-}"
OUTPUT_FILE="${4:-}"

if [[ -z "$SUMMARY_JSON" ]] || [[ -z "$REPORT_ID" ]] || [[ -z "$CHANGES_JSON" ]] || [[ -z "$OUTPUT_FILE" ]]; then
  echo "Usage: 05-report.sh SUMMARY_JSON REPORT_ID CHANGES_JSON OUTPUT_FILE" >&2
  exit 1
fi

# Get git info
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Read summary
VERDICT=$(jq -r '.verdict' "$SUMMARY_JSON")
VERDICT_REASON=$(jq -r '.verdict_reason' "$SUMMARY_JSON")

# Read changes info
BASE_COMMIT=$(jq -r '.base_commit' "$CHANGES_JSON" | cut -c1-7)
BASE_DATE=$(jq -r '.base_date' "$CHANGES_JSON")
FILES_CHANGED=$(jq -r '.files_changed' "$CHANGES_JSON")

# Emoji for verdict
case "$VERDICT" in
  CURRENT) VERDICT_EMOJI="✅" ;;
  STALE)   VERDICT_EMOJI="⚠️" ;;
  *)       VERDICT_EMOJI="❌" ;;
esac

# Start report
cat > "$OUTPUT_FILE" << EOF
# Docs Review Report: $REPORT_ID

**Generated:** $TIMESTAMP
**Branch:** $BRANCH
**Commit:** $COMMIT

## Review Scope

| Metric | Value |
|--------|-------|
| Base Commit | $BASE_COMMIT ($BASE_DATE) |
| Files Changed | $FILES_CHANGED |
| Components Affected | $(jq -r '.components | join(", ")' "$CHANGES_JSON") |

## Summary

| Metric | Value |
|--------|-------|
| Documents Reviewed | $(jq -r '.stats.total_docs' "$SUMMARY_JSON") |
| Current | $(jq -r '.stats.docs_current' "$SUMMARY_JSON") |
| Stale | $(jq -r '.stats.docs_stale' "$SUMMARY_JSON") |
| Errors | $(jq -r '.stats.docs_error' "$SUMMARY_JSON") |
| Total Issues | $(jq -r '.stats.total_issues' "$SUMMARY_JSON") |
| **Overall Verdict** | $VERDICT_EMOJI $VERDICT |

## Verdict

**$VERDICT**: $VERDICT_REASON

---

## Results by Document

EOF

# Add stale docs first (if any)
STALE_COUNT=$(jq -r '[.results[] | select(.status == "STALE")] | length' "$SUMMARY_JSON")
if [[ "$STALE_COUNT" -gt 0 ]]; then
  echo "### Documents Needing Updates" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  jq -r '.results[] | select(.status == "STALE") | @base64' "$SUMMARY_JSON" | while read -r encoded; do
    result=$(echo "$encoded" | base64 -d)
    doc_path=$(echo "$result" | jq -r '.doc_path')
    reason=$(echo "$result" | jq -r '.reason')

    echo "#### ⚠️ $doc_path" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "**Reason:** $reason" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    # List issues
    issues_count=$(echo "$result" | jq '.issues | length')
    if [[ "$issues_count" -gt 0 ]]; then
      echo "**Issues:**" >> "$OUTPUT_FILE"
      echo "" >> "$OUTPUT_FILE"
      echo "| Type | Description | Suggestion |" >> "$OUTPUT_FILE"
      echo "|------|-------------|------------|" >> "$OUTPUT_FILE"
      echo "$result" | jq -r '.issues[] | "| \(.type) | \(.description | gsub("\n"; " ")) | \(.suggestion | gsub("\n"; " ")) |"' >> "$OUTPUT_FILE"
      echo "" >> "$OUTPUT_FILE"
    fi
  done

  echo "---" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
fi

# Add current docs
CURRENT_COUNT=$(jq -r '[.results[] | select(.status == "CURRENT")] | length' "$SUMMARY_JSON")
if [[ "$CURRENT_COUNT" -gt 0 ]]; then
  echo "### Current Documents" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
  echo "These documents are up to date:" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  jq -r '.results[] | select(.status == "CURRENT") | "- ✅ \(.doc_path)"' "$SUMMARY_JSON" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
fi

# Add error docs
ERROR_COUNT=$(jq -r '[.results[] | select(.status == "ERROR")] | length' "$SUMMARY_JSON")
if [[ "$ERROR_COUNT" -gt 0 ]]; then
  echo "### Documents with Errors" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  jq -r '.results[] | select(.status == "ERROR") | @base64' "$SUMMARY_JSON" | while read -r encoded; do
    result=$(echo "$encoded" | base64 -d)
    doc_path=$(echo "$result" | jq -r '.doc_path')
    reason=$(echo "$result" | jq -r '.reason')

    echo "- ❌ **$doc_path**: $reason" >> "$OUTPUT_FILE"
  done
  echo "" >> "$OUTPUT_FILE"
fi

# Add changed files section
cat >> "$OUTPUT_FILE" << 'EOF'

---

## Changed Files

<details>
<summary>Click to expand list of changed files</summary>

EOF

jq -r '.files[] | "- `\(.path)` (\(.type))"' "$CHANGES_JSON" >> "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" << 'EOF'

</details>
EOF

# Add raw JSON output
cat >> "$OUTPUT_FILE" << 'EOF'

---

## Raw Data

<details>
<summary>Click to expand raw JSON results</summary>

```json
EOF

jq '.' "$SUMMARY_JSON" >> "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" << 'EOF'
```

</details>
EOF

echo "Report written to: $OUTPUT_FILE" >&2
