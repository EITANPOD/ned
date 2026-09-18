#!/usr/bin/env bash
# guard-labels.sh against a fake `gh` on PATH (same shim trick as with_fake_curl).
source "$(dirname "$0")/lib.sh"
script="$(cd "$(dirname "$0")/../.." && pwd)/.github/scripts/guard-labels.sh"
assert_missing() { case "$1" in *"$2"*) _fail "$3: unexpected '$2'";; esac; }

with_fake_gh() {
  local bin; bin=$(mktemp -d)
  export FAKE_GH_LOG="$bin/gh.log"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
# Real gh rejects --slurp together with -q/--jq; fail loudly if a script relies on it.
case " $* " in *" --slurp "*) case " $* " in *" -q "*|*" --jq "*) echo "fake gh: --slurp with --jq" >&2; exit 98;; esac;; esac
case "$*" in
  "label list"*)     printf '%s\n' tier:low tier:medium tier:high needs-human human-approved allow-destroy ;;
  *"--json labels"*) printf '%s\n' ${FAKE_PR_LABELS:-} ;;  # unquoted: one label per line
  *"/events"*)
    # The real call must page, or the last 'labeled' event can be on a page we never read.
    case "$*" in *--paginate*) ;; *) echo "fake gh: /events called without --paginate: $*" >&2; exit 99 ;; esac
    # --paginate shape: one array per page, printed back to back. The newest matching event is on the last page.
    if [ -z "${FAKE_EVENT_ACTOR:-}" ]; then echo '[]'; echo '[]'
    else
      echo '[{"event":"labeled","label":{"name":"human-approved"},"actor":{"login":"stale-admin"},"created_at":"2026-09-17T09:00:00Z"}]'
      jq -cn --arg a "$FAKE_EVENT_ACTOR" '[{event:"commented",actor:{login:"bob"},created_at:"2026-09-18T11:00:00Z"},
        {event:"labeled",label:{name:"human-approved"},actor:{login:$a},created_at:"2026-09-18T12:00:00Z"}]'
    fi ;;
  *"/actions/workflows/guard.yml/runs"*)
    case "$*" in *--paginate*) ;; *) echo "fake gh: runs called without --paginate" >&2; exit 99 ;; esac
    echo '{"workflow_runs":[{"id":1,"created_at":"2026-09-18T10:00:00Z","pull_requests":[]},{"id":2,"created_at":"2026-09-18T09:00:00Z","pull_requests":[{"number":2}]}]}'
    echo '{"workflow_runs":[{"id":3,"created_at":"2026-09-18T11:00:00Z","pull_requests":[{"number":1}]}]}' ;;
  *"/permission"*)   printf '%s\n' "${FAKE_PERM:-write}" ;;
esac
exit 0
EOF
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}
with_fake_gh

run_labels() { # run_labels <tier> ; env FAKE_PR_LABELS FAKE_EVENT_ACTOR FAKE_PERM HEAD_TIME
  : > "$FAKE_GH_LOG"
  REPO=o/r PR=1 TIER="$1" HEAD_TIME="${HEAD_TIME:-2026-09-18T10:00:00Z}" bash "$script"
}

# 1. human-approved added by an admin → true, no strip
out=$(FAKE_PR_LABELS="tier:low human-approved" FAKE_EVENT_ACTOR=alice FAKE_PERM=admin run_labels low)
assert_contains "$out" "approved=true" "admin label accepted"
assert_contains "$out" "destroy_ok=false" "absent allow-destroy is false"
log=$(cat "$FAKE_GH_LOG")
assert_missing "$log" "--remove-label human-approved" "admin label not stripped"

# 2. added by a non-admin collaborator → false + strip + comment
out=$(FAKE_PR_LABELS="tier:low human-approved" FAKE_EVENT_ACTOR=mallory FAKE_PERM=write run_labels low)
assert_contains "$out" "approved=false" "write user label rejected"
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" "--remove-label human-approved" "write user label stripped"
assert_contains "$log" "pr comment" "strip is explained in a comment"

# 3. added by a bot → false + strip
out=$(FAKE_PR_LABELS="tier:low human-approved" FAKE_EVENT_ACTOR="dependabot[bot]" FAKE_PERM=admin run_labels low)
assert_contains "$out" "approved=false" "bot label rejected"
assert_contains "$(cat "$FAKE_GH_LOG")" "--remove-label human-approved" "bot label stripped"

# 4. label absent → false, no label calls at all
out=$(FAKE_PR_LABELS="tier:low" run_labels low)
assert_contains "$out" "approved=false" "absent label is false"
assert_contains "$out" "destroy_ok=false" "absent destroy label is false"
log=$(cat "$FAKE_GH_LOG")
assert_missing "$log" "--remove-label" "no strip when no label"
assert_missing "$log" "/events" "no event lookup when no label"

# 5. tier low drops needs-human; the stale tier label goes too
out=$(FAKE_PR_LABELS="tier:high needs-human" run_labels low)
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" "--remove-label needs-human" "needs-human removed at low tier"
assert_contains "$log" "--remove-label tier:high" "stale tier label removed"
assert_contains "$log" "--add-label tier:low" "current tier label added"
assert_contains "$out" "approved=false" "low tier with no human label"

# 6. non-low tier adds needs-human, and only true/false reaches stdout
out=$(FAKE_PR_LABELS="" run_labels high)
assert_contains "$(cat "$FAKE_GH_LOG")" "--add-label needs-human" "needs-human added above low"
assert_eq "approved=false
destroy_ok=false" "$out" "stdout carries only the two outputs"

# 7. label added before the current head arrived (HEAD_TIME 13:00 > label 12:00) → false + strip
out=$(FAKE_PR_LABELS="tier:low human-approved" FAKE_EVENT_ACTOR=alice FAKE_PERM=admin HEAD_TIME=2026-09-18T13:00:00Z run_labels low)
assert_contains "$out" "approved=false" "label older than the head rejected"
assert_contains "$(cat "$FAKE_GH_LOG")" "--remove-label human-approved" "stale label stripped"

# 8. the shim itself rejects --slurp with --jq, like real gh
set +e; gh api x --paginate --slurp -q . >/dev/null 2>&1; rc=$?; set -e
assert_eq 98 "$rc" "shim rejects --slurp with -q"

# 9. guard-head-runs.sh: all pages, runs of other PRs dropped (min = HEAD_TIME, max = run to re-run)
runs=$(REPO=o/r PR=1 bash "$(dirname "$script")/guard-head-runs.sh" abc123)
assert_eq "2026-09-18T10:00:00Z" "$(jq -r 'map(.created_at) | min' <<<"$runs")" "HEAD_TIME ignores another PR's earlier run"
assert_eq 3 "$(jq -r 'max_by(.created_at) | .id' <<<"$runs")" "latest run for this PR is picked for re-run"

echo "ok labels"
