#!/usr/bin/env bash
# guard-head-runs.sh <head-sha>: print (one JSON array) this repo's pull_request_target guard runs for <head-sha>
# on PR $PR: same head branch, same head repository, and linked to $PR (GitHub drops the link once a PR is
# closed, so a closed scratch PR's run for the same SHA never counts). Env: REPO, PR, BRANCH.
set -euo pipefail
: "${REPO:?}" "${PR:?}" "${BRANCH:?}"
gh api "repos/$REPO/actions/workflows/guard.yml/runs?head_sha=$1&event=pull_request_target&per_page=100" --paginate \
  | jq -cs --argjson pr "$PR" --arg b "$BRANCH" --arg r "$REPO" '[.[].workflow_runs[]
      | select(.head_branch == $b and .head_repository.full_name == $r and any(.pull_requests[]?; .number == $pr))]'
