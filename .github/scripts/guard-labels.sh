#!/usr/bin/env bash
# Manage guard labels on a PR. Env: REPO PR TIER. Prints approved= and destroy_ok=.
# Label freshness (new commits invalidate human labels) is enforced by guard.yml, not here.
set -euo pipefail
: "${REPO:?}" "${PR:?}" "${TIER:?}"

existing=$(gh label list -R "$REPO" --limit 200 --json name -q '.[].name')
ensure() { # ensure <name> <color> <description>
  grep -qx -- "$1" <<<"$existing" || gh label create "$1" --color "$2" --description "$3" -R "$REPO" >/dev/null
}
ensure tier:low 0e8a16 "guard: auto-mergeable"
ensure tier:medium fbca04 "guard: needs human-approved label"
ensure tier:high b60205 "guard: blocked; needs human-approved (+ allow-destroy)"
ensure needs-human d93f0b "guard: waiting for a human"
ensure human-approved 0052cc "human: I reviewed this PR at its current head"
ensure allow-destroy 5319e7 "human: terraform destroys in this PR are intended"

current=$(gh pr view "$PR" -R "$REPO" --json labels -q '.labels[].name')
for l in tier:low tier:medium tier:high; do
  if grep -qx -- "$l" <<<"$current" && [ "$l" != "tier:$TIER" ]; then
    gh pr edit "$PR" -R "$REPO" --remove-label "$l" >/dev/null
  fi
done
grep -qx -- "tier:$TIER" <<<"$current" || gh pr edit "$PR" -R "$REPO" --add-label "tier:$TIER" >/dev/null
if [ "$TIER" = low ]; then
  if grep -qx -- needs-human <<<"$current"; then gh pr edit "$PR" -R "$REPO" --remove-label needs-human >/dev/null; fi
else
  grep -qx -- needs-human <<<"$current" || gh pr edit "$PR" -R "$REPO" --add-label needs-human >/dev/null
fi

valid_label() { # valid_label <name> → 0 if the last 'labeled' event for it was added by a non-bot admin
  local ev actor
  ev=$(gh api "repos/$REPO/issues/$PR/events" --paginate --slurp \
    -q "add | [.[] | select(.event==\"labeled\" and .label.name==\"$1\")] | last | select(.) | \"\(.actor.login) \(.created_at)\"")
  [ -n "$ev" ] || return 1
  actor=${ev%% *}
  [ -n "$actor" ] || return 1
  [[ "$actor" != *"[bot]" ]] || return 1
  [ "$(gh api "repos/$REPO/collaborators/$actor/permission" -q .permission)" = admin ]
}
check() { # check <label> → prints true/false; strips an invalid label. Only true/false on stdout.
  if grep -qx -- "$1" <<<"$current"; then
    if valid_label "$1"; then echo true; return; fi
    gh pr edit "$PR" -R "$REPO" --remove-label "$1" >/dev/null
    gh pr comment "$PR" -R "$REPO" \
      --body "guard: removed label \`$1\` — it must be added by a repo admin (not a bot, not an automation)." >/dev/null
  fi
  echo false
}
printf 'approved=%s\n' "$(check human-approved)"
printf 'destroy_ok=%s\n' "$(check allow-destroy)"
