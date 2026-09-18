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
case "$*" in
  "label list"*)     printf '%s\n' tier:low tier:medium tier:high needs-human human-approved allow-destroy ;;
  *"--json labels"*) printf '%s\n' ${FAKE_PR_LABELS:-} ;;  # unquoted: one label per line
  *"/events"*)       [ -z "${FAKE_EVENT_ACTOR:-}" ] || printf '%s 2026-09-18T12:00:00Z\n' "$FAKE_EVENT_ACTOR" ;;
  *"/permission"*)   printf '%s\n' "${FAKE_PERM:-write}" ;;
esac
exit 0
EOF
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}
with_fake_gh

run_labels() { # run_labels <tier> ; env FAKE_PR_LABELS FAKE_EVENT_ACTOR FAKE_PERM
  : > "$FAKE_GH_LOG"
  REPO=o/r PR=1 TIER="$1" bash "$script"
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

echo "ok labels"
