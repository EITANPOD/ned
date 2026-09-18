#!/usr/bin/env bash
# Claude Code PreToolUse hook: block destructive commands in this repo. Exit 2 = block.
set -euo pipefail
input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
[ "$tool" = "Bash" ] || exit 0
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

deny='(^|[;&|[:space:]])(terraform[[:space:]]+(apply|destroy|import)|terraform[[:space:]]+state[[:space:]]+rm|git[[:space:]]+push[[:space:]]+.*(--force|-f)([[:space:]]|$)|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+branch[[:space:]]+-D|rm[[:space:]]+-rf|gh[[:space:]]+pr[[:space:]]+merge|gh[[:space:]]+secret|gh[[:space:]]+variable[[:space:]]+set|gh[[:space:]]+api[[:space:]]+.*-X[[:space:]]+(DELETE|PUT|PATCH)|aws[[:space:]]+iam[[:space:]]|aws[[:space:]]+s3[[:space:]]+r[mb][[:space:]]|aws[[:space:]]+ssm[[:space:]]+(put|delete)-parameter|aws[[:space:]]+sts[[:space:]]+assume-role)'
if [[ "$cmd" =~ $deny ]]; then
  cat >&2 <<EOF
Blocked by Ned guardrails: '${BASH_REMATCH[2]}' is not allowed from an agent session.
Safe alternative: open a PR and let the guard check decide; for applies use the infra-aws workflow (manual dispatch, prod approval); for secrets/variables ask the human on Telegram.
EOF
  exit 2
fi
exit 0
