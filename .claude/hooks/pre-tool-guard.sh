#!/usr/bin/env bash
# Claude Code PreToolUse hook: block destructive commands in this repo. Exit 2 = block.
set -euo pipefail
input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
[ "$tool" = "Bash" ] || exit 0
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

F='[[:space:]]+'                      # one-or-more spaces
OPT='([[:space:]]+-[^[:space:]]+)*'   # zero-or-more flags like -chdir=x (flag tokens only)
rules=(
  "terraform${OPT}${F}(apply|destroy|import)"
  "terraform${OPT}${F}state${F}rm"
  "git${F}push([[:space:]]+[^[:space:]]+)*${F}(--force(-with-lease)?|-f)([[:space:]]|$)"
  "git${F}reset${F}--hard"
  "git${F}branch${F}-D"
  "rm${F}(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*|-r${F}-f|-f${F}-r)([[:space:]]|$)"
  "gh${F}pr${F}merge"
  "gh${F}secret"
  "gh${F}variable${F}set"
  "gh${F}api([[:space:]]+[^[:space:]]+)*${F}(-X|--method)${F}(DELETE|PUT|PATCH)"
  "aws([[:space:]]+-?[^[:space:]]+)*${F}iam([[:space:]]|$)"
  "aws([[:space:]]+-?[^[:space:]]+)*${F}s3${F}r[mb]([[:space:]]|$)"
  "aws([[:space:]]+-?[^[:space:]]+)*${F}ssm${F}(put|delete)-parameter"
  "aws([[:space:]]+-?[^[:space:]]+)*${F}sts${F}assume-role"
)
deny="(^|[;&|[:space:](])($(IFS='|'; echo "${rules[*]}"))"

if [[ "$cmd" =~ $deny ]]; then
  match="${BASH_REMATCH[0]:${#BASH_REMATCH[1]}}"
  match="${match%"${match##*[![:space:]]}"}"
  cat >&2 <<EOF
Blocked by Ned guardrails: '${match}' is not allowed from an agent session.
Safe alternative: open a PR and let the guard check decide; for applies use the infra-aws workflow (manual dispatch, prod approval); for secrets/variables ask the human on Telegram.
EOF
  exit 2
fi
exit 0
