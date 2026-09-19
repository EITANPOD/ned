#!/usr/bin/env bash
# guard-marked.sh <marker>: exit 0 if a comment by the guard itself (github-actions[bot]) starts with <marker>.
# Env: COMMENTS_JSON (one JSON array, default comments.json). Anyone can comment on a public PR, so markers from others are ignored.
set -euo pipefail
jq -e --arg m "$1" 'any(.[]; .user.login == "github-actions[bot]" and ((.body // "") | startswith($m)))' \
  "${COMMENTS_JSON:-comments.json}" >/dev/null
