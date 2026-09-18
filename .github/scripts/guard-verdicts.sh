#!/usr/bin/env bash
# Parse reviewer verdicts bound to the current head.
# Env: COMMENTS_JSON, REVIEWS_JSON (files, one JSON array each), HEAD_SHA, HEAD_TIME (server-set ISO time the head arrived).
# Prints claude=, coderabbit=, suggested_fix=.
set -euo pipefail
: "${HEAD_SHA:?}" "${HEAD_TIME:?}"
# Only the real Claude App, and only a comment written (or updated) after this head was pushed.
claude_body=$(jq -r --arg t "$HEAD_TIME" '[.[] | select(.user.login == "claude[bot]" and .user.type == "Bot"
  and ((.updated_at // .created_at) > $t))] | last | .body // ""' "$COMMENTS_JSON" | tr -d '\r')
verdict_line=$(printf '%s\n' "$claude_body" | grep -E '^[[:space:]]*VERDICT: (PASS|HUMAN REVIEW REQUIRED)[[:space:]]*$' | tail -1 || true)
case "$verdict_line" in
  *"HUMAN REVIEW REQUIRED"*) claude=human;;
  *"PASS"*) claude=pass;;
  *) claude=missing;;
esac
fix=$(printf '%s\n' "$claude_body" | sed -n 's/^Suggested fix: *//p' | head -1)

# CodeRabbit counts only when it reviewed exactly this head.
cr=$(jq -r --arg h "$HEAD_SHA" '[.[] | select(.user.login == "coderabbitai[bot]" and .commit_id == $h)]
  | last | select(.) | "\(.state)|\(.body // "")"' "$REVIEWS_JSON")
coderabbit=missing
if [ -n "$cr" ]; then
  case "$cr" in
    APPROVED\|*|*"Actionable comments posted: 0"*) coderabbit=clean;;
    *) coderabbit=findings;;
  esac
fi
printf 'claude=%s\ncoderabbit=%s\nsuggested_fix=%s\n' "$claude" "$coderabbit" "$fix"
