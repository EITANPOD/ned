#!/usr/bin/env bash
# guard-head-runs.sh <head-sha>: print (one JSON array) this repo's pull_request_target guard runs for <head-sha>
# that belong to PR $PR. Runs often carry no pull_requests link, so only runs linked to another PR are dropped.
# Env: REPO, PR.
set -euo pipefail
: "${REPO:?}" "${PR:?}"
gh api "repos/$REPO/actions/workflows/guard.yml/runs?head_sha=$1&event=pull_request_target&per_page=100" --paginate \
  | jq -cs --argjson pr "$PR" '[.[].workflow_runs[] | select((.pull_requests | length) == 0 or any(.pull_requests[]; .number == $pr))]'
