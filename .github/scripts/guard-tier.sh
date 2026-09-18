#!/usr/bin/env bash
# Classify a PR's risk tier. stdin: "<STATUS>\t<path>" lines. Env: PR_TITLE PR_ACTOR PLAN_FILE FORCE_PUSH CLAUDE_VERDICT.
# Prints tier=, reasons=, destroys=.
set -euo pipefail
tier=low; reasons=(); destroys=0
bump() { # bump <level> <reason>
  case "$1:$tier" in high:*) tier=high;; medium:low) tier=medium;; esac
  reasons+=("$2")
}

touches_infra=false
while IFS=$'\t' read -r status path newpath || [ -n "${status:-}" ]; do
  status=${status%$'\r'}; path=${path%$'\r'}; newpath=${newpath%$'\r'}
  [ -z "${path:-}" ] && continue
  case "$status" in
    R*|C*)
      old=$path; path=$newpath
      case "$old" in infra/*|.github/*) bump high "rename/copy out of protected path ($old)";; esac
      ;;
  esac
  case "$path" in
    infra/bootstrap/*) touches_infra=true; bump high "infra/bootstrap changed ($path)";;
    .github/workflows/guard.yml|.github/actions/*|.github/scripts/*) bump high "guard/notify tooling changed ($path)";;
    # evidence producers: the plan text and the Claude verdict the guard trusts
    .github/workflows/infra-aws.yml|.github/workflows/claude-review.yml) bump high "guard evidence workflow changed ($path)";;
    .claude/*|CLAUDE.md|.coderabbit.yaml|.github/CODEOWNERS) bump high "agent/reviewer rules changed ($path)";;
    infra/aws/*) touches_infra=true; bump medium "infra/aws changed ($path)";;
    infra/*) touches_infra=true; bump medium "infra changed ($path)";;
    .github/workflows/*) bump medium "workflow changed ($path)";;
    deploy/*) bump medium "deploy changed ($path)";;
    apps/*|docs/*|tests/*|README.md|.github/dependabot.yml) ;;   # low
    *) bump medium "unclassified path ($path)";;
  esac
  case "$status" in D) case "$path" in infra/*|.github/*) bump high "deletion under protected path ($path)";; esac;; esac
done

if [ "$touches_infra" = true ]; then
  if [ -z "${PLAN_FILE:-}" ] || [ ! -f "$PLAN_FILE" ]; then
    bump high "infra changed but no terraform plan available"
  else
    destroys=$(sed -E -n 's/^Plan: .* ([0-9]+) to destroy(, [0-9]+ to forget)?\.$/\1/p' "$PLAN_FILE" | tail -1)
    destroys=${destroys:-0}
    if [ "$destroys" -gt 0 ]; then bump high "plan destroys ${destroys} resource(s)"; fi
  fi
fi

if [ "${PR_ACTOR:-}" = "dependabot[bot]" ]; then
  version_pattern="from ([0-9]+)\.[^ ]* to ([0-9]+)\."
  if [[ "${PR_TITLE:-}" =~ $version_pattern ]]; then
    if [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]; then bump medium "dependabot major bump"; fi
  fi
fi

[ "${FORCE_PUSH:-false}" = true ] && bump high "force push on PR branch"
[ "${CLAUDE_VERDICT:-}" = human ] && bump medium "reviewer requested human review"

printf 'tier=%s\n' "$tier"
( IFS=';'; printf 'reasons=%s\n' "${reasons[*]:-none}" )
printf 'destroys=%s\n' "$destroys"
