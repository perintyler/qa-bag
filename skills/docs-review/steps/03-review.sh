#!/bin/bash
#
# Step 3: Review a single documentation file
# Uses Claude to check if the doc is stale based on changes
#
# Usage: 03-review.sh REPO_ROOT DOC_PATH CHANGES_JSON OUTPUT_FILE
# Output: JSON result written to OUTPUT_FILE
#

set -euo pipefail

REPO_ROOT="${1:-}"
DOC_PATH="${2:-}"
CHANGES_JSON="${3:-}"
OUTPUT_FILE="${4:-}"

if [[ -z "$REPO_ROOT" ]] || [[ -z "$DOC_PATH" ]] || [[ -z "$CHANGES_JSON" ]] || [[ -z "$OUTPUT_FILE" ]]; then
  echo "Usage: 03-review.sh REPO_ROOT DOC_PATH CHANGES_JSON OUTPUT_FILE" >&2
  exit 1
fi

DOC_FULL_PATH="$REPO_ROOT/$DOC_PATH"

if [[ ! -f "$DOC_FULL_PATH" ]]; then
  echo "{\"doc_path\": \"$DOC_PATH\", \"status\": \"ERROR\", \"reason\": \"File not found\"}" > "$OUTPUT_FILE"
  exit 0
fi

# Get the directory this doc is in
DOC_DIR=$(dirname "$DOC_PATH")

# Filter changes to those relevant to this doc
# A doc is related to changes in its directory or subdirectories
RELEVANT_CHANGES=$(jq -r --arg dir "$DOC_DIR" '
  .files // [] | map(select(type == "object" and .path)) | map(select(
    .path | startswith($dir + "/") or
    ($dir == "." and (.path | contains("/") | not))
  )) | map(.path) | join("\n")
' "$CHANGES_JSON" 2>/dev/null || echo "")

# If doc is at root level, consider all changes
if [[ "$DOC_DIR" == "." ]]; then
  RELEVANT_CHANGES=$(jq -r '.files // [] | map(select(type == "object" and .path)) | map(.path) | join("\n")' "$CHANGES_JSON" 2>/dev/null || echo "")
fi

# Count relevant changes (trim whitespace and handle empty)
if [[ -z "$RELEVANT_CHANGES" ]]; then
  RELEVANT_COUNT=0
else
  RELEVANT_COUNT=$(echo "$RELEVANT_CHANGES" | grep -c . 2>/dev/null || echo 0)
  RELEVANT_COUNT=$(echo "$RELEVANT_COUNT" | tr -d '[:space:]')
fi

# If no relevant changes, doc is likely current
if [[ "$RELEVANT_COUNT" -eq 0 ]]; then
  cat > "$OUTPUT_FILE" << EOF
{
  "doc_path": "$DOC_PATH",
  "status": "CURRENT",
  "reason": "No relevant code changes in related directories",
  "relevant_changes": 0,
  "issues": []
}
EOF
  exit 0
fi

# Build the prompt for Claude
PROMPT="You are a documentation reviewer. Check if this documentation is outdated based on recent code changes.

Documentation file: $DOC_PATH
Documentation directory: $DOC_DIR

Recent code changes in related directories:
$RELEVANT_CHANGES

Instructions:
1. Read the documentation file at $DOC_FULL_PATH
2. For each changed file listed, examine what changed (using git diff or reading the file)
3. Determine if any documentation is now outdated due to these changes

Look for these staleness indicators:
- API changes: Function signatures, parameters, return types changed but not documented
- Config changes: Environment variables, config keys added/removed/renamed
- Flow changes: Business logic or control flow significantly altered
- Dependency changes: Dependencies added/removed that affect documented usage
- Feature changes: New features not documented, removed features still documented
- Examples outdated: Code examples that no longer work

CRITICAL: Your final response must be ONLY valid JSON:
{
  \"doc_path\": \"$DOC_PATH\",
  \"status\": \"CURRENT\" or \"STALE\",
  \"reason\": \"Brief summary of why\",
  \"relevant_changes\": $RELEVANT_COUNT,
  \"issues\": [
    {\"type\": \"api_change|config_change|flow_change|dependency_change|feature_change|example_outdated\", \"description\": \"What is outdated\", \"suggestion\": \"How to fix it\"}
  ]
}

Set status to STALE only if there are concrete issues. Minor changes that don't affect documentation should be marked CURRENT."

# Run via barry query command
BARRY_CLI="${BARRY_CLI:-barry}"

result=$("$BARRY_CLI" query -p "$PROMPT" -t "Bash,Read,Grep,Glob" -m 10 2>&1) || true

# Try to extract JSON from result
if json_part=$(echo "$result" | sed -n '/```json/,/```/p' | grep -v '```' | tr -d '\n') && echo "$json_part" | jq -e . >/dev/null 2>&1; then
  echo "$json_part" > "$OUTPUT_FILE"
elif echo "$result" | jq -e '.doc_path' >/dev/null 2>&1; then
  echo "$result" > "$OUTPUT_FILE"
else
  # Couldn't parse, save error
  cat > "$OUTPUT_FILE" << EOF
{
  "doc_path": "$DOC_PATH",
  "status": "ERROR",
  "reason": "Failed to parse Claude output",
  "relevant_changes": $RELEVANT_COUNT,
  "issues": [],
  "raw_output": $(echo "$result" | jq -Rs .)
}
EOF
fi
