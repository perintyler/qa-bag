#!/bin/bash
#
# Docs Review Orchestrator
# Main entry point - coordinates the docs review pipeline
#
# Usage: docs-review.sh [--full] [--filter=PATTERN] [--since=COMMIT]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEPS_DIR="$SCRIPT_DIR/steps"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REPORTS_DIR="$SCRIPT_DIR/.reports"
STATE_FILE="$SCRIPT_DIR/.last-review"

# Defaults
FULL_REVIEW=false
FILTER=""
SINCE_COMMIT=""

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --full)
      FULL_REVIEW=true
      shift
      ;;
    --filter=*)
      FILTER="${1#*=}"
      shift
      ;;
    --since=*)
      SINCE_COMMIT="${1#*=}"
      shift
      ;;
    --help|-h)
      cat << EOF
Docs Review Agent - Check documentation for staleness

Usage: docs-review.sh [OPTIONS]

Options:
  --full              Force review all docs (ignore last review state)
  --filter=PATTERN    Only review docs matching pattern
  --since=COMMIT      Review changes since specific commit
  --help              Show this help

Examples:
  ./docs-review.sh                    # Review changes since last review
  ./docs-review.sh --full             # Full review of all docs
  ./docs-review.sh --filter=mcp       # Only docs in mcp/
  ./docs-review.sh --since=abc123     # Changes since specific commit

Output:
  Reports are written to: $REPORTS_DIR/
EOF
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage" >&2
      exit 1
      ;;
    *)
      shift
      ;;
  esac
done

# Generate identifiers
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")
BRANCH_SAFE=$(echo "$BRANCH" | tr '/' '-')
REPORT_ID="$TIMESTAMP-$BRANCH_SAFE"

# Create temp directory for intermediate files
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$REPORTS_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  Docs Review Agent"
echo "  Report ID: $REPORT_ID"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────────────
# Step 1: Find Documentation
# ─────────────────────────────────────────────────────────────────

echo "Step 1: Finding Documentation"
echo "─────────────────────────────"

DOCS_FILE="$WORK_DIR/docs.json"

FILTER_ARG=""
if [[ -n "$FILTER" ]]; then
  FILTER_ARG="--filter=$FILTER"
fi

bash "$STEPS_DIR/01-find-docs.sh" "$REPO_ROOT" $FILTER_ARG > "$DOCS_FILE"

DOCS_COUNT=$(jq -r '.docs | length' "$DOCS_FILE")
echo "  Found $DOCS_COUNT documentation files"

if [[ "$DOCS_COUNT" -eq 0 ]]; then
  echo "  No documentation files found."
  exit 0
fi

jq -r '.docs[] | "    - \(.path)"' "$DOCS_FILE" | head -10
if [[ "$DOCS_COUNT" -gt 10 ]]; then
  echo "    ... and $((DOCS_COUNT - 10)) more"
fi

echo ""

# ─────────────────────────────────────────────────────────────────
# Step 2: Get Changes Since Last Review
# ─────────────────────────────────────────────────────────────────

echo "Step 2: Getting Changes"
echo "───────────────────────"

CHANGES_FILE="$WORK_DIR/changes.json"

# Determine base commit
if [[ -n "$SINCE_COMMIT" ]]; then
  BASE_COMMIT="$SINCE_COMMIT"
elif [[ "$FULL_REVIEW" == "true" ]]; then
  # For full review, get all commits (use initial commit)
  BASE_COMMIT=$(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD | head -1)
elif [[ -f "$STATE_FILE" ]]; then
  BASE_COMMIT=$(jq -r '.last_commit // ""' "$STATE_FILE")
  if [[ -z "$BASE_COMMIT" ]] || ! git -C "$REPO_ROOT" cat-file -e "$BASE_COMMIT" 2>/dev/null; then
    echo "  Warning: Last review commit not found, using full review"
    BASE_COMMIT=$(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD | head -1)
  fi
else
  echo "  No previous review found, using full review"
  BASE_COMMIT=$(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD | head -1)
fi

bash "$STEPS_DIR/02-get-changes.sh" "$REPO_ROOT" "$BASE_COMMIT" > "$CHANGES_FILE"

CHANGES_COUNT=$(jq -r '.files_changed' "$CHANGES_FILE")
COMPONENTS=$(jq -r '.components | join(", ")' "$CHANGES_FILE")

echo "  Base commit: $(echo "$BASE_COMMIT" | cut -c1-7)"
echo "  Files changed: $CHANGES_COUNT"
if [[ -n "$COMPONENTS" ]]; then
  echo "  Components affected: $COMPONENTS"
fi
echo ""

if [[ "$CHANGES_COUNT" -eq 0 ]] && [[ "$FULL_REVIEW" != "true" ]]; then
  echo "  No changes since last review."
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  ✅ Verdict: CURRENT"
  echo "  No changes to review"
  echo "═══════════════════════════════════════════════════════════"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────
# Step 3: Review Documentation (parallel)
# ─────────────────────────────────────────────────────────────────

echo "Step 3: Reviewing Documentation"
echo "────────────────────────────────"

RESULTS_DIR="$WORK_DIR/results"
mkdir -p "$RESULTS_DIR"

# Launch review for each doc in parallel
pids=()
while IFS='|' read -r doc_path related_dirs; do
  echo "  Reviewing: $doc_path"
  safe_name=$(echo "$doc_path" | tr '/' '-' | tr '.' '-')
  bash "$STEPS_DIR/03-review.sh" "$REPO_ROOT" "$doc_path" "$CHANGES_FILE" "$RESULTS_DIR/$safe_name.json" &
  pids+=($!)
done < <(jq -r '.docs[] | "\(.path)|\(.related_dirs | join(","))"' "$DOCS_FILE")

# Wait for all to complete
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

echo "  All reviews completed"
echo ""

# ─────────────────────────────────────────────────────────────────
# Step 4: Aggregate Results
# ─────────────────────────────────────────────────────────────────

echo "Step 4: Aggregating Results"
echo "───────────────────────────"

SUMMARY_FILE="$WORK_DIR/summary.json"
bash "$STEPS_DIR/04-aggregate.sh" "$RESULTS_DIR" "$DOCS_FILE" > "$SUMMARY_FILE"

# Print results
jq -r '.results[] | "\(.status)|\(.doc_path)|\(.reason // "-")"' "$SUMMARY_FILE" | while IFS='|' read -r status doc_path reason; do
  case "$status" in
    CURRENT) echo "  ✅ $doc_path: Current" ;;
    STALE)   echo "  ⚠️  $doc_path: Stale ($reason)" ;;
    ERROR)   echo "  ❌ $doc_path: Error ($reason)" ;;
    *)       echo "  ❓ $doc_path: Unknown" ;;
  esac
done

echo ""

# ─────────────────────────────────────────────────────────────────
# Step 5: Generate Report
# ─────────────────────────────────────────────────────────────────

echo "Step 5: Generating Report"
echo "─────────────────────────"

REPORT_FILE="$REPORTS_DIR/report-$REPORT_ID.md"
bash "$STEPS_DIR/05-report.sh" "$SUMMARY_FILE" "$REPORT_ID" "$CHANGES_FILE" "$REPORT_FILE"

echo ""

# ─────────────────────────────────────────────────────────────────
# Update State
# ─────────────────────────────────────────────────────────────────

# Update last review state
HEAD_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD)
cat > "$STATE_FILE" << EOF
{
  "last_commit": "$HEAD_COMMIT",
  "last_review": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# ─────────────────────────────────────────────────────────────────
# Final Verdict
# ─────────────────────────────────────────────────────────────────

VERDICT=$(jq -r '.verdict' "$SUMMARY_FILE")
VERDICT_REASON=$(jq -r '.verdict_reason' "$SUMMARY_FILE")

case "$VERDICT" in
  CURRENT) VERDICT_EMOJI="✅" ;;
  STALE)   VERDICT_EMOJI="⚠️" ;;
  *)       VERDICT_EMOJI="❌" ;;
esac

echo "═══════════════════════════════════════════════════════════"
echo "  $VERDICT_EMOJI Verdict: $VERDICT"
echo "  $VERDICT_REASON"
echo ""
echo "  Report: $REPORT_FILE"
echo "═══════════════════════════════════════════════════════════"

# Exit code: 0 for CURRENT, 1 for STALE/ERROR
[[ "$VERDICT" == "CURRENT" ]] && exit 0 || exit 1
