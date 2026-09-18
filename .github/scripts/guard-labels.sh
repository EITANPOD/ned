#!/usr/bin/env bash
# Manage guard labels on a PR. Env: REPO PR HEAD_SHA TIER. Prints approved= and destroy_ok=.
set -euo pipefail
: "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}" "${TIER:?}"

ensure() { gh label create "$1" --color "$2" --description "$3" --force -R "$REPO" >/dev/null; }
ensure tier:low 0e8a16 "guard: auto-mergeable"
ensure tier:medium fbca04 "guard: needs human-approved label"
ensure tier:high b60205 "guard: blocked; needs human-approved (+ allow-destroy)"
ensure needs-human d93f0b "guard: waiting for a human"
ensure human-approved 0052cc "human: I reviewed this PR at its current head"
ensure allow-destroy 5319e7 "human: terraform destroys in this PR are intended"

current=$(gh pr view "$PR" -R "$REPO" --json labels -q '.labels[].name')
for l in tier:low tier:medium tier:high; do
  if grep -qx "$l" <<<"$current" && [ "$l" != "tier:$TIER" ]; then gh pr edit "$PR" -R "$REPO" --remove-label "$l"; fi
done
grep -qx "tier:$TIER" <<<"$current" || gh pr edit "$PR" -R "$REPO" --add-label "tier:$TIER"
if [ "$TIER" = low ]; then
  grep -qx needs-human <<<"$current" && gh pr edit "$PR" -R "$REPO" --remove-label needs-human || true
else
  grep -qx needs-human <<<"$current" || gh pr edit "$PR" -R "$REPO" --add-label needs-human
fi

head_time=$(gh api "repos/$REPO/commits/$HEAD_SHA" -q .commit.committer.date)
valid_label() { # valid_label <name> → 0 if last 'labeled' event for it is by an admin after head_time
  local ev; ev=$(gh api "repos/$REPO/issues/$PR/events" --paginate -q "[.[] | select(.event==\"labeled\" and .label.name==\"$1\")] | last | \"\(.actor.login) \(.created_at)\"")
  [ -n "$ev" ] && [ "$ev" != "null null" ] || return 1
  local actor when; actor=${ev% *}; when=${ev#* }
  [[ "$actor" != *"[bot]" ]] || return 1
  [ "$(gh api "repos/$REPO/collaborators/$actor/permission" -q .permission)" = admin ] || return 1
  [[ "$when" > "$head_time" ]]
}
check() { # check <label> → prints true/false; strips a stale/invalid label
  if grep -qx "$1" <<<"$current"; then
    if valid_label "$1"; then echo true; return; fi
    gh pr edit "$PR" -R "$REPO" --remove-label "$1"
    gh pr comment "$PR" -R "$REPO" --body "guard: removed label \`$1\` — it must be added by an admin after the current head commit ($HEAD_SHA)."
  fi
  echo false
}
printf 'approved=%s\n' "$(check human-approved)"
printf 'destroy_ok=%s\n' "$(check allow-destroy)"
