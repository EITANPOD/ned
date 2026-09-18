#!/usr/bin/env bash
# Parse reviewer verdicts. Env: COMMENTS_JSON, REVIEWS_JSON (file paths). Prints claude=, coderabbit=, suggested_fix=.
set -euo pipefail
claude_body=$(jq -r '[.[] | select(.user.login | test("^claude(\\[bot\\])?$"))] | last | .body // ""' "$COMMENTS_JSON")
claude=missing
case "$claude_body" in
  *"VERDICT: PASS"*) claude=pass;;
  *"VERDICT: HUMAN REVIEW REQUIRED"*) claude=human;;
esac
fix=$(printf '%s\n' "$claude_body" | sed -n 's/^Suggested fix: *//p' | head -1)

cr=$(jq -r '[.[] | select(.user.login=="coderabbitai[bot]")] | last | select(.) | "\(.state)|\(.body // "")"' "$REVIEWS_JSON")
coderabbit=missing
if [ "$cr" != "null" ] && [ -n "$cr" ]; then
  case "$cr" in
    APPROVED\|*|*"Actionable comments posted: 0"*) coderabbit=clean;;
    *) coderabbit=findings;;
  esac
fi
printf 'claude=%s\ncoderabbit=%s\nsuggested_fix=%s\n' "$claude" "$coderabbit" "$fix"
