# Phase 0b: Guardrails & Human-in-the-Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every PR is classified Low/Medium/High by a mechanical `guard` check; Low auto-merges, Medium/High block until a human labels them, and Telegram gets an alert with the reviewer's suggested fix. Agents in this repo are denied destructive commands.

**Architecture:** Three small bash scripts (`guard-tier.sh`, `guard-verdicts.sh`, `notify.sh`) with plain-bash self-tests, wired by two workflows (`guard.yml`, `main-red.yml`) and one composite action (`telegram-notify`). Reviewer STOP rules live in `CLAUDE.md`/`.coderabbit.yaml`/the Claude prompt and emit a machine-readable `VERDICT:` line the guard parses. A `.claude/settings.json` deny-list plus a PreToolUse hook stop Claude Code sessions from running apply/merge/secret commands.

**Tech Stack:** GitHub Actions (checkout v7, pinned majors as in Phase 0), `gh` CLI, bash + jq, Telegram Bot API (`sendMessage`, HTML), Claude Code hooks (PreToolUse), pre-commit.

**Spec:** `docs/superpowers/specs/2026-09-18-guardrails-design.md`

## Global Constraints

- Tiers: **Low** = only `apps/**`, `docs/**`, `tests/**`, `README.md`, Dependabot minor/patch, no deletions under `infra/**` or `.github/**`. **Medium** = `infra/aws/**` add/change-only plan, `.github/workflows/**` (except guard/notify), Dependabot major, `deploy/**`. **High** = plan destroys ≥1, `infra/bootstrap/**`, `.github/workflows/guard.yml`, `.github/actions/**`, `.github/scripts/**`, `.claude/**`, `CLAUDE.md`, `.coderabbit.yaml`, `.github/CODEOWNERS`, gitleaks hit, force-push. Highest wins. Plan artifact missing on an infra PR → High.
- Labels: `tier:low`, `tier:medium`, `tier:high`, `needs-human`, `human-approved`, `allow-destroy`. `human-approved`/`allow-destroy` count only if added by an admin after the current head commit.
- Verdict line: exactly `VERDICT: PASS` or `VERDICT: HUMAN REVIEW REQUIRED`, optional `Suggested fix:` paragraph after it.
- CodeRabbit clean = latest review by `coderabbitai[bot]` is `APPROVED` or its body contains `Actionable comments posted: 0`.
- Auto-merge only for Low, same-repo, non-draft, both verdicts clean: `gh pr merge --auto --squash`.
- Telegram: secrets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`; HTML parse mode; notify step `continue-on-error: true`; token never echoed.
- Deny-list for agents (exact): `terraform apply`, `terraform destroy`, `terraform import`, `terraform state rm`, `git push --force`, `git push -f`, `git reset --hard`, `git branch -D`, `rm -rf`, `gh pr merge`, `gh secret`, `gh variable set`, `gh api -X DELETE|PUT|PATCH`, `aws iam`, `aws s3 rm`, `aws s3 rb`, `aws ssm put-parameter`, `aws ssm delete-parameter`, `aws sts assume-role`.
- Conventional commits, plain messages, no attribution lines. Every action pinned to a major tag. Branch protection required checks become `lint`, `check`, `guard`.

---

## File Structure

```
.github/
  actions/telegram-notify/
    action.yml            composite: runs notify.sh with inputs message, silent
    notify.sh             POST sendMessage; escapes HTML; never prints the token
  scripts/
    guard-tier.sh         stdin: changed files (NUL-safe lines "A|M|D<TAB>path"); env PR_TITLE, PR_ACTOR, PLAN_FILE, FORCE_PUSH; stdout: tier=, reasons=
    guard-verdicts.sh     env COMMENTS_JSON, REVIEWS_JSON (paths); stdout: claude=, coderabbit=, suggested_fix=
    guard-labels.sh       env REPO, PR, HEAD_SHA, TIER; ensures labels exist, sets tier label, validates human labels; stdout: approved=, destroy_ok=
  workflows/
    guard.yml             required check; classify → labels → auto-merge or block → telegram
    main-red.yml          workflow_run failure on main → telegram
    telegram-ping.yml     workflow_dispatch: "Ned guardrails online"
tests/guard/
  run.sh                  runs every test_*.sh, fails on first red
  lib.sh                  assert_eq, assert_contains, fake curl PATH shim helper
  test_tier.sh            fixtures → expected tiers
  test_verdicts.sh        fixture comment/review JSON → expected verdicts
  test_notify.sh          fake curl records payload → assert chat_id, parse_mode, escaped text
  test_hook.sh            feeds commands to the PreToolUse hook → expect exit 2 / 0
  fixtures/               plan-adds.txt plan-destroy.txt comments-pass.json comments-human.json reviews-clean.json reviews-findings.json
.claude/
  settings.json           permissions.deny + allow; PreToolUse hook registration
  hooks/pre-tool-guard.sh reads tool_input.command JSON on stdin; blocks deny-list with a suggested alternative
CLAUDE.md                 + "STOP conditions" and "Agents never merge/apply/touch secrets"
.coderabbit.yaml          path_instructions mirror STOP list
.github/workflows/claude-review.yml   prompt requires VERDICT line
.github/workflows/infra-aws.yml       destroy alert in plan job; apply pending/failed/succeeded alerts
.github/workflows/pre-commit.yml      + run tests/guard/run.sh
README.md                 guardrails section + runbook (secrets, repo settings)
```

---

### Task 1: Test harness + Telegram notify action + ping workflow

**Files:**
- Create: `tests/guard/lib.sh`, `tests/guard/run.sh`, `tests/guard/test_notify.sh`, `.github/actions/telegram-notify/notify.sh`, `.github/actions/telegram-notify/action.yml`, `.github/workflows/telegram-ping.yml`
- Modify: `.github/workflows/pre-commit.yml` (add test step)

**Interfaces:**
- Produces: `notify.sh` contract — env `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `MESSAGE` (HTML allowed), optional `SILENT=true`; exit 0 on HTTP 200, exit 1 otherwise, never prints the token. Composite action inputs `message`, `silent` (default `false`).
- Produces: test lib functions `assert_eq expected actual msg`, `assert_contains haystack needle msg`, `with_fake_curl` (prepends `tests/guard/.fake-bin` to PATH; fake curl appends its argv to `$FAKE_CURL_LOG` and prints `{"ok":true}`).

- [ ] **Step 1: Write the test lib and runner**

`tests/guard/lib.sh`:
```bash
#!/usr/bin/env bash
# Minimal assertions for guard scripts. Source this file.
set -euo pipefail
_fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" == "$2" ] || _fail "$3: expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) _fail "$3: '$2' not in '$1'";; esac; }
# Fake curl: records argv, returns Telegram-style ok JSON.
with_fake_curl() {
  local bin; bin=$(mktemp -d)
  export FAKE_CURL_LOG="$bin/curl.log"
  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FAKE_CURL_LOG"
echo '{"ok":true}'
EOF
  chmod +x "$bin/curl"
  export PATH="$bin:$PATH"
}
```

`tests/guard/run.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for t in test_*.sh; do
  echo "== $t"; bash "$t"
done
echo "all guard tests passed"
```

- [ ] **Step 2: Write the failing notify test**

`tests/guard/test_notify.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
with_fake_curl
export TELEGRAM_BOT_TOKEN=tok123 TELEGRAM_CHAT_ID=42
MESSAGE='<b>hi</b> a<b & c' SILENT=true bash ../../.github/actions/telegram-notify/notify.sh
log=$(cat "$FAKE_CURL_LOG")
assert_contains "$log" "https://api.telegram.org/bottok123/sendMessage" "url"
assert_contains "$log" "chat_id=42" "chat id"
assert_contains "$log" "parse_mode=HTML" "parse mode"
assert_contains "$log" "disable_notification=true" "silent"
# raw '<b' inside text must be escaped, but our own <b> tags are allowed via the RAW_HTML marker rule:
assert_contains "$log" "text=<b>hi</b> a&lt;b &amp; c" "escaping"
echo "ok notify"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash tests/guard/run.sh`
Expected: FAIL — `notify.sh: No such file or directory`.

- [ ] **Step 4: Write `notify.sh`**

Escaping rule (simple and testable): the message may use exactly these tags: `<b>`, `</b>`, `<i>`, `</i>`, `<code>`, `</code>`, `<a href="...">`, `</a>`. Everything else with `<`, `>`, `&` is escaped. Implementation: escape all, then un-escape the allowed tags.

```bash
#!/usr/bin/env bash
# Send one Telegram message. Env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, MESSAGE, SILENT (true/false).
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?}" "${TELEGRAM_CHAT_ID:?}" "${MESSAGE:?}"
silent=${SILENT:-false}

esc=$(printf '%s' "$MESSAGE" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
# re-allow a fixed tag whitelist
esc=$(printf '%s' "$esc" | sed -E \
  -e 's#&lt;(/?)(b|i|code)&gt;#<\1\2>#g' \
  -e 's#&lt;a href=&quot;([^&]*)&quot;&gt;#<a href="\1">#g' \
  -e 's#&lt;a href="([^"]*)"&gt;#<a href="\1">#g' \
  -e 's#&lt;/a&gt;#</a>#g')

resp=$(curl -sS --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_notification=${silent}" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "text=${esc}")
case "$resp" in *'"ok":true'*) echo "telegram: sent";; *) echo "telegram: failed: ${resp//$TELEGRAM_BOT_TOKEN/***}" >&2; exit 1;; esac
```

Note for the test: `--data-urlencode "text=..."` is passed as one argv element, so the fake curl log contains the literal `text=<b>hi</b> a&lt;b &amp; c`.

- [ ] **Step 5: Run tests to verify pass**

Run: `bash tests/guard/run.sh`
Expected: `ok notify` and `all guard tests passed`.

- [ ] **Step 6: Write the composite action**

`.github/actions/telegram-notify/action.yml`:
```yaml
name: telegram-notify
description: Send a Telegram message via the Ned bot (HTML; never fails the caller)
inputs:
  message:
    description: HTML message (tags allowed: b, i, code, a)
    required: true
  silent:
    description: disable notification sound
    required: false
    default: "false"
runs:
  using: composite
  steps:
    - shell: bash
      continue-on-error: true
      env:
        MESSAGE: ${{ inputs.message }}
        SILENT: ${{ inputs.silent }}
      run: bash "${{ github.action_path }}/notify.sh"
```
Callers must set `env: TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}` and `TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}` on the step (composite actions do not see caller secrets otherwise).

- [ ] **Step 7: Write the ping workflow**

`.github/workflows/telegram-ping.yml`:
```yaml
name: telegram-ping

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: ./.github/actions/telegram-notify
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: "🟢 <b>Ned guardrails online</b> — ${{ github.repository }}"
```

- [ ] **Step 8: Add the test step to `pre-commit.yml`**

After the `pre-commit run --all-files --show-diff-on-failure` step append:
```yaml
      - run: bash tests/guard/run.sh
```

- [ ] **Step 9: Lint + commit**

Run: `pre-commit run --all-files` → all Passed/Skipped (shell files need the executable bit: `chmod +x tests/guard/*.sh .github/actions/telegram-notify/notify.sh`).
```bash
git add tests/guard .github/actions/telegram-notify .github/workflows/telegram-ping.yml .github/workflows/pre-commit.yml
git commit -m "feat(ci): telegram notify action with self-test and ping workflow"
```

---

### Task 2: Tier classifier `guard-tier.sh`

**Files:**
- Create: `.github/scripts/guard-tier.sh`, `tests/guard/test_tier.sh`, `tests/guard/fixtures/plan-adds.txt`, `tests/guard/fixtures/plan-destroy.txt`

**Interfaces:**
- Produces: `guard-tier.sh` reads changed files on stdin, one per line as `<STATUS>\t<path>` where STATUS is `A|M|D|R` (from `gh pr diff --name-status`-style output; the guard workflow produces it with `git diff --name-status`). Env: `PR_TITLE`, `PR_ACTOR`, `PLAN_FILE` (path or empty), `FORCE_PUSH` (`true|false`). Prints exactly two lines: `tier=low|medium|high` and `reasons=<semicolon-separated>`.

- [ ] **Step 1: Write fixtures**

`tests/guard/fixtures/plan-adds.txt`:
```
Plan: 3 to add, 1 to change, 0 to destroy.
```
`tests/guard/fixtures/plan-destroy.txt`:
```
  # aws_iam_role.old will be destroyed
Plan: 0 to add, 0 to change, 1 to destroy.
```

- [ ] **Step 2: Write the failing test**

`tests/guard/test_tier.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S=../../.github/scripts/guard-tier.sh
run() { # run <files> [env assignments...]
  local files=$1; shift
  printf '%b' "$files" | env "$@" bash "$S"
}
t() { run "$1" "${@:2}" | sed -n 's/^tier=//p'; }

assert_eq low    "$(t 'M\tapps/core/x.py\nA\tdocs/a.md\nM\tREADME.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "app+docs is low"
assert_eq medium "$(t 'M\tinfra/aws/iam.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "infra/aws add-only is medium"
assert_eq high   "$(t 'M\tinfra/aws/iam.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false)" "destroy is high"
assert_eq high   "$(t 'M\tinfra/aws/iam.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "infra without plan is high"
assert_eq high   "$(t 'M\tinfra/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "bootstrap is high"
assert_eq medium "$(t 'M\t.github/workflows/ci.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "workflow edit is medium"
assert_eq high   "$(t 'M\t.github/workflows/guard.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "guard edit is high"
assert_eq high   "$(t 'M\tCLAUDE.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "CLAUDE.md is high"
assert_eq high   "$(t 'M\t.claude/settings.json' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" ".claude is high"
assert_eq high   "$(t 'D\tinfra/aws/logging.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "deleting infra file is high"
assert_eq low    "$(t 'M\t.github/dependabot.yml' PR_TITLE='chore(deps): bump actions/checkout from 7.0.1 to 7.0.2' 'PR_ACTOR=dependabot[bot]' PLAN_FILE= FORCE_PUSH=false)" "dependabot patch is low"
assert_eq medium "$(t 'M\t.github/workflows/ci.yml' PR_TITLE='chore(deps): bump actions/checkout from 7.0.1 to 8.0.0' 'PR_ACTOR=dependabot[bot]' PLAN_FILE= FORCE_PUSH=false)" "dependabot major is medium"
assert_eq high   "$(t 'M\tapps/x.py' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=true)" "force push is high"
r=$(run 'M\tinfra/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false | sed -n 's/^reasons=//p')
assert_contains "$r" "infra/bootstrap" "reason names bootstrap"
assert_contains "$r" "destroy" "reason names destroy"
echo "ok tier"
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/guard/run.sh` → FAIL on `guard-tier.sh: No such file`.

- [ ] **Step 4: Write `guard-tier.sh`**

```bash
#!/usr/bin/env bash
# Classify a PR's risk tier. stdin: "<STATUS>\t<path>" lines. Env: PR_TITLE PR_ACTOR PLAN_FILE FORCE_PUSH.
set -euo pipefail
tier=low; reasons=()
bump() { # bump <level> <reason>
  case "$1:$tier" in high:*) tier=high;; medium:low) tier=medium;; esac
  reasons+=("$2")
}

touches_infra=false
while IFS=$'\t' read -r status path; do
  [ -z "${path:-}" ] && continue
  case "$path" in
    infra/bootstrap/*) bump high "infra/bootstrap changed ($path)";;
    .github/workflows/guard.yml|.github/actions/*|.github/scripts/*) bump high "guard/notify tooling changed ($path)";;
    .claude/*|CLAUDE.md|.coderabbit.yaml|.github/CODEOWNERS) bump high "agent/reviewer rules changed ($path)";;
    infra/aws/*) touches_infra=true; bump medium "infra/aws changed ($path)";;
    infra/*) touches_infra=true; bump medium "infra changed ($path)";;
    .github/workflows/*) bump medium "workflow changed ($path)";;
    deploy/*) bump medium "deploy changed ($path)";;
    apps/*|docs/*|tests/*|README.md|.github/dependabot.yml) ;;   # low
    *) bump medium "unclassified path ($path)";;
  esac
  case "$status" in D|R*) case "$path" in infra/*|.github/*) bump high "deletion under protected path ($path)";; esac;; esac
done

if [ "$touches_infra" = true ]; then
  if [ -z "${PLAN_FILE:-}" ] || [ ! -f "$PLAN_FILE" ]; then
    bump high "infra changed but no terraform plan available"
  else
    destroys=$(sed -n 's/^Plan: .* \([0-9]\+\) to destroy\.$/\1/p' "$PLAN_FILE" | tail -1)
    if [ "${destroys:-0}" -gt 0 ]; then bump high "plan destroys ${destroys} resource(s)"; fi
  fi
fi

if [ "${PR_ACTOR:-}" = "dependabot[bot]" ]; then
  if [[ "${PR_TITLE:-}" =~ from\ ([0-9]+)\.[^ ]*\ to\ ([0-9]+)\. ]]; then
    if [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]; then bump medium "dependabot major bump"; fi
  fi
fi

[ "${FORCE_PUSH:-false}" = true ] && bump high "force push on PR branch"

printf 'tier=%s\n' "$tier"
( IFS=';'; printf 'reasons=%s\n' "${reasons[*]:-none}" )
```

Note on Dependabot: a patch bump touching only `.github/dependabot.yml`/`apps`/`docs` stays Low; a bump that edits a workflow file is Medium by path anyway, matching the spec ("Dependabot minor/patch" is Low only when its paths are Low).

- [ ] **Step 5: Run tests to verify pass**

Run: `bash tests/guard/run.sh` → `ok tier`. If the "dependabot patch is low" case fails because the fixture path `.github/dependabot.yml` is not in the Low list, the Low list above already includes it — check for typos.

- [ ] **Step 6: Commit**

```bash
chmod +x .github/scripts/guard-tier.sh tests/guard/test_tier.sh
git add .github/scripts/guard-tier.sh tests/guard
git commit -m "feat(ci): risk tier classifier for PRs with tests"
```

---

### Task 3: Verdict parser `guard-verdicts.sh`

**Files:**
- Create: `.github/scripts/guard-verdicts.sh`, `tests/guard/test_verdicts.sh`, fixtures `comments-pass.json`, `comments-human.json`, `comments-none.json`, `reviews-clean.json`, `reviews-findings.json`, `reviews-none.json`

**Interfaces:**
- Produces: env `COMMENTS_JSON` (path to `gh api repos/O/R/issues/N/comments` output) and `REVIEWS_JSON` (path to `gh api repos/O/R/pulls/N/reviews` output). Prints three lines: `claude=pass|human|missing`, `coderabbit=clean|findings|missing`, `suggested_fix=<single line, may be empty>`.

- [ ] **Step 1: Write fixtures**

`comments-pass.json`:
```json
[{"user":{"login":"claude[bot]"},"body":"## Review\nAll good.\n\nVERDICT: PASS\n"}]
```
`comments-human.json`:
```json
[{"user":{"login":"github-actions[bot]"},"body":"### terraform plan"},
 {"user":{"login":"claude[bot]"},"body":"Trust policy widened.\n\nVERDICT: HUMAN REVIEW REQUIRED\nSuggested fix: pin Principal to arn:aws:iam::123:role/ned-*\nMore text.\n"}]
```
`comments-none.json`: `[]`
`reviews-clean.json`:
```json
[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","body":"**Actionable comments posted: 0**\n\nsummary"}]
```
`reviews-findings.json`:
```json
[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","body":"**Actionable comments posted: 7**"}]
```
`reviews-none.json`: `[]`

- [ ] **Step 2: Write the failing test**

`tests/guard/test_verdicts.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S=../../.github/scripts/guard-verdicts.sh
v() { COMMENTS_JSON=fixtures/$1 REVIEWS_JSON=fixtures/$2 bash "$S"; }
out=$(v comments-pass.json reviews-clean.json)
assert_contains "$out" "claude=pass" "pass"
assert_contains "$out" "coderabbit=clean" "clean"
out=$(v comments-human.json reviews-findings.json)
assert_contains "$out" "claude=human" "human"
assert_contains "$out" "coderabbit=findings" "findings"
assert_contains "$out" "suggested_fix=pin Principal to arn:aws:iam::123:role/ned-*" "fix extracted"
out=$(v comments-none.json reviews-none.json)
assert_contains "$out" "claude=missing" "missing claude"
assert_contains "$out" "coderabbit=missing" "missing cr"
echo "ok verdicts"
```

- [ ] **Step 3: Run to verify it fails** — `bash tests/guard/run.sh` → FAIL, script missing.

- [ ] **Step 4: Write `guard-verdicts.sh`**

```bash
#!/usr/bin/env bash
# Parse reviewer verdicts. Env: COMMENTS_JSON, REVIEWS_JSON (file paths). Prints claude=, coderabbit=, suggested_fix=.
set -euo pipefail
claude_body=$(jq -r '[.[] | select(.user.login | test("^claude(\\[bot\\])?$"))] | last | .body // ""' "$COMMENTS_JSON")
claude=missing
case "$claude_body" in
  *"VERDICT: PASS"*) claude=pass;;
  *"VERDICT: HUMAN REVIEW REQUIRED"*) claude=human;;
esac
fix=$(printf '%s\n' "$claude_body" | sed -n 's/^Suggested fix: *//p' | head -1)

cr=$(jq -r '[.[] | select(.user.login=="coderabbitai[bot]")] | last | "\(.state)|\(.body // "")"' "$REVIEWS_JSON")
coderabbit=missing
if [ "$cr" != "null" ] && [ -n "$cr" ]; then
  case "$cr" in
    APPROVED\|*|*"Actionable comments posted: 0"*) coderabbit=clean;;
    *) coderabbit=findings;;
  esac
fi
printf 'claude=%s\ncoderabbit=%s\nsuggested_fix=%s\n' "$claude" "$coderabbit" "$fix"
```

- [ ] **Step 5: Run tests** → `ok verdicts`.

- [ ] **Step 6: Commit**

```bash
chmod +x .github/scripts/guard-verdicts.sh tests/guard/test_verdicts.sh
git add .github/scripts/guard-verdicts.sh tests/guard
git commit -m "feat(ci): reviewer verdict parser with tests"
```

---

### Task 4: Label manager `guard-labels.sh` + `guard.yml` + repo settings

**Files:**
- Create: `.github/scripts/guard-labels.sh`, `.github/workflows/guard.yml`
- Modify: `README.md` (guardrails section + runbook)

**Interfaces:**
- Consumes: `guard-tier.sh`, `guard-verdicts.sh`, telegram-notify action.
- Produces: `guard-labels.sh` env `REPO`, `PR`, `HEAD_SHA`, `TIER`; ensures the six labels exist, sets exactly one `tier:*` label, adds/removes `needs-human` (present iff tier ≠ low), validates `human-approved` and `allow-destroy` (added by an admin, after the head commit's timestamp; otherwise removed with a PR comment), prints `approved=true|false` and `destroy_ok=true|false`.

- [ ] **Step 1: Write `guard-labels.sh`** (no unit test: it is `gh` glue; covered by the e2e in Task 7)

```bash
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
```

- [ ] **Step 2: Write `guard.yml`**

```yaml
name: guard

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, labeled, unlabeled]
  workflow_run:
    workflows: [claude-review, infra-aws]
    types: [completed]

permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read

concurrency:
  group: guard-${{ github.event.pull_request.number || github.event.workflow_run.pull_requests[0].number || github.run_id }}
  cancel-in-progress: true

jobs:
  guard:
    if: github.event_name == 'pull_request' || github.event.workflow_run.pull_requests[0] != null
    runs-on: ubuntu-latest
    env:
      GH_TOKEN: ${{ github.token }}
      REPO: ${{ github.repository }}
      PR: ${{ github.event.pull_request.number || github.event.workflow_run.pull_requests[0].number }}
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
          fetch-depth: 0

      - name: PR facts
        id: pr
        run: |
          gh pr view "$PR" --json headRefOid,baseRefOid,title,author,isDraft,headRepository,url \
            -q '"head=\(.headRefOid)\nbase=\(.baseRefOid)\ntitle=\(.title)\nactor=\(.author.login)\ndraft=\(.isDraft)\nfork=\(.headRepository.nameWithOwner != env.REPO)\nurl=\(.url)"' >> "$GITHUB_OUTPUT"

      - name: Changed files (name-status)
        run: |
          git fetch -q origin "${{ steps.pr.outputs.head }}"
          git diff --name-status "${{ steps.pr.outputs.base }}...${{ steps.pr.outputs.head }}" > changed.txt
          # force push: previous head (from PR timeline) not an ancestor of current head
          prev=$(gh api "repos/$REPO/pulls/$PR/commits" -q 'if length>1 then .[-2].sha else empty end')
          if [ -n "$prev" ] && ! git merge-base --is-ancestor "$prev" "${{ steps.pr.outputs.head }}"; then echo "FORCE_PUSH=true" >> "$GITHUB_ENV"; else echo "FORCE_PUSH=false" >> "$GITHUB_ENV"; fi

      - name: Latest terraform plan text for this head (if any)
        run: |
          rid=$(gh run list --workflow=infra-aws.yml --json databaseId,headSha,status -q "[.[] | select(.headSha==\"${{ steps.pr.outputs.head }}\" and .status==\"completed\")] | first | .databaseId")
          if [ -n "$rid" ] && [ "$rid" != null ]; then gh run download "$rid" -n plan-text -D plan || true; fi
          [ -f plan/plan.txt ] && echo "PLAN_FILE=plan/plan.txt" >> "$GITHUB_ENV" || echo "PLAN_FILE=" >> "$GITHUB_ENV"

      - name: Classify
        id: tier
        env:
          PR_TITLE: ${{ steps.pr.outputs.title }}
          PR_ACTOR: ${{ steps.pr.outputs.actor }}
        run: bash .github/scripts/guard-tier.sh < changed.txt | tee -a "$GITHUB_OUTPUT"

      - name: Verdicts
        id: verdicts
        run: |
          gh api "repos/$REPO/issues/$PR/comments" --paginate > comments.json
          gh api "repos/$REPO/pulls/$PR/reviews" --paginate > reviews.json
          COMMENTS_JSON=comments.json REVIEWS_JSON=reviews.json bash .github/scripts/guard-verdicts.sh | tee -a "$GITHUB_OUTPUT"

      - name: Labels
        id: labels
        env:
          HEAD_SHA: ${{ steps.pr.outputs.head }}
          TIER: ${{ steps.tier.outputs.tier }}
        run: bash .github/scripts/guard-labels.sh | tee -a "$GITHUB_OUTPUT"

      - name: Summary
        run: |
          {
            echo "## guard: tier **${{ steps.tier.outputs.tier }}**"
            echo "- reasons: ${{ steps.tier.outputs.reasons }}"
            echo "- claude: ${{ steps.verdicts.outputs.claude }} · coderabbit: ${{ steps.verdicts.outputs.coderabbit }}"
            echo "- human-approved: ${{ steps.labels.outputs.approved }} · allow-destroy: ${{ steps.labels.outputs.destroy_ok }}"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Alert (medium/high, once per head)
        if: steps.tier.outputs.tier != 'low'
        run: |
          marker="<!-- guard-alerted:${{ steps.pr.outputs.head }} -->"
          if gh pr view "$PR" --json comments -q '.comments[].body' | grep -qF "$marker"; then echo "already alerted"; exit 0; fi
          gh pr comment "$PR" --body "$marker guard: tier ${{ steps.tier.outputs.tier }} — Telegram alert sent."
          echo "ALERT=1" >> "$GITHUB_ENV"
      - uses: ./.github/actions/telegram-notify
        if: env.ALERT == '1'
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: |
            ${{ steps.tier.outputs.tier == 'high' && '🛑 <b>HIGH</b>' || '🟠 <b>MEDIUM</b>' }} | PR #${{ env.PR }} ${{ steps.pr.outputs.title }}
            Why: ${{ steps.tier.outputs.reasons }}
            Reviewers: claude=${{ steps.verdicts.outputs.claude }}, coderabbit=${{ steps.verdicts.outputs.coderabbit }}
            Suggested fix: ${{ steps.verdicts.outputs.suggested_fix || 'n/a' }}
            <a href="${{ steps.pr.outputs.url }}">PR</a> · approve by adding label <code>human-approved</code>${{ contains(steps.tier.outputs.reasons, 'destroy') && ' + <code>allow-destroy</code>' || '' }}

      - name: Decide
        run: |
          tier=${{ steps.tier.outputs.tier }}
          clean=false
          [ "${{ steps.verdicts.outputs.claude }}" = pass ] && [ "${{ steps.verdicts.outputs.coderabbit }}" = clean ] && clean=true
          case "$tier" in
            low)
              if [ "$clean" = true ] && [ "${{ steps.pr.outputs.draft }}" = false ] && [ "${{ steps.pr.outputs.fork }}" = false ]; then
                gh pr merge "$PR" --auto --squash && echo "auto-merge armed"
              else
                echo "low tier but not clean/draft/fork — waiting (no block)"
              fi ;;
            medium)
              [ "${{ steps.labels.outputs.approved }}" = true ] || { echo "::error::medium tier: add label human-approved"; exit 1; } ;;
            high)
              [ "${{ steps.labels.outputs.approved }}" = true ] || { echo "::error::high tier: add label human-approved"; exit 1; }
              if echo "${{ steps.tier.outputs.reasons }}" | grep -q destroy; then
                [ "${{ steps.labels.outputs.destroy_ok }}" = true ] || { echo "::error::plan destroys resources: add label allow-destroy"; exit 1; }
              fi ;;
          esac

      - uses: ./.github/actions/telegram-notify
        if: steps.tier.outputs.tier == 'low' && success()
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          silent: "true"
          message: "🟢 low | PR #${{ env.PR }} ${{ steps.pr.outputs.title }} — auto-merge armed (claude=${{ steps.verdicts.outputs.claude }}, coderabbit=${{ steps.verdicts.outputs.coderabbit }})"
```

- [ ] **Step 3: README guardrails section** (append after "PR review bots")

```markdown
### Guardrails (guard check)

Every PR gets a risk tier from `.github/scripts/guard-tier.sh` (paths, terraform plan destroys, Dependabot semver, force-push):

| Tier | Merge | You get |
|---|---|---|
| low | auto-merge once `lint`, `check`, `guard` are green and both reviewers report clean | silent Telegram digest |
| medium | blocked until you add label `human-approved` | Telegram alert with reasons + reviewer's suggested fix |
| high | blocked until `human-approved` (+ `allow-destroy` for destroys) | same, marked HIGH |

Labels only count when added by an admin after the PR's current head commit; the guard strips stale ones.
Reviewer verdicts are machine-read: Claude must post `VERDICT: PASS` or `VERDICT: HUMAN REVIEW REQUIRED` + `Suggested fix:`; CodeRabbit must report `Actionable comments posted: 0`.

One-time setup: secrets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (create the bot with @BotFather, `/start` it, read your chat id from `getUpdates`); enable auto-merge on the repo; add `guard` to the required checks:

```bash
gh api -X PATCH repos/<owner>/<repo> -f allow_auto_merge=true
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'EOF'
{"required_status_checks":{"strict":true,"contexts":["lint","check","guard"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false,"required_linear_history":true}
EOF
```
Test the bot: Actions → `telegram-ping` → Run.
```

- [ ] **Step 4: Lint + commit**

`pre-commit run --all-files` clean; `bash tests/guard/run.sh` green.
```bash
chmod +x .github/scripts/guard-labels.sh
git add .github/scripts/guard-labels.sh .github/workflows/guard.yml README.md
git commit -m "feat(ci): guard check - tiers, labels, auto-merge, telegram alerts"
```

---

### Task 5: Reviewer STOP rules + infra-aws alerts + main-red alert

**Files:**
- Modify: `CLAUDE.md`, `.github/workflows/claude-review.yml` (prompt), `.coderabbit.yaml`, `.github/workflows/infra-aws.yml`
- Create: `.github/workflows/main-red.yml`

**Interfaces:**
- Consumes: telegram-notify action; verdict format from Task 3.

- [ ] **Step 1: `CLAUDE.md` — append**

```markdown
## STOP conditions (reviewers)
Any of these in a PR means the verdict is `VERDICT: HUMAN REVIEW REQUIRED`, followed by a `Suggested fix:` line:
- IAM trust policies, permissions boundaries, or the CI role policy change
- wildcard (`*`) actions or resources added to any policy
- secrets, tokens, or credentials appear in the diff
- workflow `permissions` widen, an action loses its version pin, or a required check is removed
- tests are deleted or weakened; a check is disabled
- terraform plan destroys anything
- changes to `.github/workflows/guard.yml`, `.github/actions/**`, `.github/scripts/**`, `.claude/**`, `CLAUDE.md`, `.coderabbit.yaml`
Otherwise end the review with `VERDICT: PASS`. The verdict line is machine-read by the guard check; always include exactly one.

## Rules for agents working in this repo
- Never merge, apply Terraform, force-push, or touch secrets/variables. Open a PR; the guard check decides.
- Something unusual (drift, failing apply, unclear spec) → stop and say so in the PR; the human gets a Telegram alert.
```

- [ ] **Step 2: `claude-review.yml` prompt** — replace the prompt block with:

```yaml
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}

            Review this pull request against the rules in CLAUDE.md, including its
            STOP conditions. Report only concrete problems: security issues,
            correctness bugs, drift from the design spec, over-engineering, weak tests.
            Skip style nits.

            Post ONE overall comment with `gh pr comment` containing: a verdict line
            (exactly `VERDICT: PASS` or `VERDICT: HUMAN REVIEW REQUIRED`), at most five
            bullets, and when not PASS a line starting with `Suggested fix:` giving the
            concrete change. Use the inline comment tool (confirmed: true) only for
            defects you can point to by file and line.
```

- [ ] **Step 3: `.coderabbit.yaml`** — add a third `path_instructions` entry and tighten the first two:

```yaml
    - path: "**"
      instructions: "Escalate (do not just suggest) when: IAM trust/boundary/CI-role changes, wildcard actions or resources, secrets in diff, workflow permission widening or unpinned actions, deleted tests, terraform destroys, or edits under .github/workflows/guard.yml, .github/actions, .github/scripts, .claude, CLAUDE.md, .coderabbit.yaml. State the concrete fix."
```

- [ ] **Step 4: `infra-aws.yml` alerts** — add after the plan step in `plan` job (pull_request only):

```yaml
      - name: Destroy alert
        if: github.event_name == 'pull_request'
        id: destroys
        run: |
          d=$(sed -n 's/^Plan: .* \([0-9]\+\) to destroy\.$/\1/p' plan.txt | tail -1)
          echo "count=${d:-0}" >> "$GITHUB_OUTPUT"
      - uses: ./.github/actions/telegram-notify
        if: github.event_name == 'pull_request' && steps.destroys.outputs.count != '0'
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: "🛑 <b>terraform plan destroys ${{ steps.destroys.outputs.count }} resource(s)</b> in PR #${{ github.event.pull_request.number }} — review the plan comment before adding <code>allow-destroy</code>."
```
And in the `plan` job when dispatched with `action=apply` (after the S3 stash step):
```yaml
      - uses: ./.github/actions/telegram-notify
        if: github.event_name == 'workflow_dispatch' && inputs.action == 'apply'
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: "⏳ infra/aws apply is waiting for your <b>prod</b> approval — <a href=\"${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}\">approve</a>"
```
And at the end of the `apply` job, two steps:
```yaml
      - uses: ./.github/actions/telegram-notify
        if: success()
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: "✅ infra/aws applied (run ${{ github.run_id }})"
      - uses: ./.github/actions/telegram-notify
        if: failure()
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: "❌ <b>infra/aws apply FAILED</b> — <a href=\"${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}\">logs</a>. Suggested first step: re-run once (IAM propagation); if it fails again, open the log and do not re-dispatch."
```
The `apply` job's checkout must stay before these steps (the composite action lives in the repo).

- [ ] **Step 5: `main-red.yml`**

```yaml
name: main-red

on:
  workflow_run:
    workflows: [pre-commit, infra-aws, guard]
    types: [completed]
    branches: [main]

permissions:
  contents: read

jobs:
  alert:
    if: github.event.workflow_run.conclusion == 'failure'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: ./.github/actions/telegram-notify
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          message: "❌ <b>${{ github.event.workflow_run.name }} failed on main</b> — <a href=\"${{ github.event.workflow_run.html_url }}\">run</a>"
```

- [ ] **Step 6: Lint + commit**

`pre-commit run --all-files` clean.
```bash
git add CLAUDE.md .github/workflows/claude-review.yml .coderabbit.yaml .github/workflows/infra-aws.yml .github/workflows/main-red.yml
git commit -m "feat(ci): reviewer STOP rules with machine-readable verdicts; telegram alerts for plan destroys, apply, and red main"
```

---

### Task 6: Agent-side guardrails (`.claude/settings.json` + PreToolUse hook)

**Files:**
- Create: `.claude/settings.json`, `.claude/hooks/pre-tool-guard.sh`, `tests/guard/test_hook.sh`

**Interfaces:**
- Produces: hook reads Claude Code's PreToolUse JSON on stdin (`.tool_name`, `.tool_input.command`); exit 2 + stderr message blocks the call; exit 0 allows.

- [ ] **Step 1: Write the failing hook test**

`tests/guard/test_hook.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
H=../../.claude/hooks/pre-tool-guard.sh
blocked() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | bash "$H" 2>/tmp/hook.err; echo $?; }
for c in "terraform apply -auto-approve" "cd infra && terraform destroy" "git push --force origin main" "git push -f" "git reset --hard HEAD~1" "rm -rf ./x" "gh pr merge 3 --squash" "gh secret set X" "gh variable set X --body y" "gh api -X DELETE repos/a/b" "aws iam create-user --user-name x" "aws s3 rm s3://b/k" "aws ssm put-parameter --name n" "aws sts assume-role --role-arn r"; do
  assert_eq 2 "$(blocked "$c")" "block: $c"
done
assert_contains "$(cat /tmp/hook.err)" "Blocked by Ned guardrails" "message"
for c in "terraform plan" "terraform test" "git push origin feature" "gh pr view 3" "aws sts get-caller-identity" "rm -f tmp.txt" "gh api repos/a/b"; do
  assert_eq 0 "$(blocked "$c")" "allow: $c"
done
printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | bash "$H"; assert_eq 0 $? "non-bash tools pass"
echo "ok hook"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/guard/run.sh` → FAIL, hook missing.

- [ ] **Step 3: Write the hook**

```bash
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
```

- [ ] **Step 4: Run tests** → `ok hook`.

- [ ] **Step 5: Write `.claude/settings.json`**

```json
{
  "permissions": {
    "allow": [
      "Bash(terraform fmt:*)", "Bash(terraform validate:*)", "Bash(terraform test:*)", "Bash(terraform plan:*)", "Bash(terraform init:*)",
      "Bash(gh pr view:*)", "Bash(gh pr checks:*)", "Bash(gh pr diff:*)", "Bash(gh run list:*)", "Bash(gh run view:*)",
      "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(aws sts get-caller-identity:*)",
      "Bash(pre-commit run:*)", "Bash(bash tests/guard/run.sh)"
    ],
    "deny": [
      "Bash(terraform apply:*)", "Bash(terraform destroy:*)", "Bash(terraform import:*)", "Bash(terraform state rm:*)",
      "Bash(git push --force:*)", "Bash(git push -f:*)", "Bash(git reset --hard:*)", "Bash(git branch -D:*)",
      "Bash(rm -rf:*)", "Bash(gh pr merge:*)", "Bash(gh secret:*)", "Bash(gh variable set:*)",
      "Bash(aws iam:*)", "Bash(aws s3 rm:*)", "Bash(aws s3 rb:*)", "Bash(aws ssm put-parameter:*)", "Bash(aws ssm delete-parameter:*)", "Bash(aws sts assume-role:*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-tool-guard.sh" }]
      }
    ]
  }
}
```

- [ ] **Step 6: Lint + commit**

```bash
chmod +x .claude/hooks/pre-tool-guard.sh tests/guard/test_hook.sh
pre-commit run --all-files
git add .claude tests/guard/test_hook.sh
git commit -m "feat(agents): deny-list and PreToolUse hook for destructive commands"
```

---

### Task 7: Repo settings, secrets check, end-to-end verification

**Files:** none (ops).

- [ ] **Step 1: Secrets present?**

Run: `gh secret list -R EITANPOD/ned | cut -f1`
Expected: `CLAUDE_CODE_OAUTH_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`. If the Telegram ones are missing, stop and ask the human (they create the bot).

- [ ] **Step 2: Open the Phase 0b PR** (branch `phase0b` → `main`), wait for `lint`/`check`; guard is not yet a required check so this PR merges on the old rules. Human merges (the PR itself is High: it adds guard/.claude).

- [ ] **Step 3: Repo settings (after merge)**

```bash
gh api -X PATCH repos/EITANPOD/ned -f allow_auto_merge=true -q .allow_auto_merge
gh api -X PUT repos/EITANPOD/ned/branches/main/protection --input - <<'EOF'
{"required_status_checks":{"strict":true,"contexts":["lint","check","guard"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false,"required_linear_history":true}
EOF
gh workflow run telegram-ping -R EITANPOD/ned
```
Expected: `true`; protection JSON lists three contexts; Telegram receives "Ned guardrails online".

- [ ] **Step 4: E2E Low** — branch `test/guard-low`, edit `README.md` (add a line), open PR. Expected within ~5 min: labels `tier:low`; Claude comment ends with `VERDICT: PASS`; CodeRabbit clean (post `@coderabbitai review` if under 10 stars); guard green; PR auto-merges; silent Telegram digest.

- [ ] **Step 5: E2E Medium** — branch `test/guard-medium`, change `log_retention_days` default 14→30 in `infra/aws/variables.tf`, open PR. Expected: plan comment "1 to change"; labels `tier:medium`, `needs-human`; guard red with "add label human-approved"; Telegram alert with reasons. Add label `human-approved` → guard reruns green → merge manually (medium never auto-merges) → dispatch apply → Telegram "waiting for prod approval" → approve → Telegram "applied". Then revert via another Medium PR (or leave at 30 — decide and note in ledger).

- [ ] **Step 6: E2E High** — branch `test/guard-high`, delete `aws_sns_topic_policy` from `infra/aws/budgets.tf`, open PR. Expected: plan "1 to destroy"; Telegram destroy alert from infra-aws; labels `tier:high`; guard red requiring both labels. Close the PR without merging.

- [ ] **Step 7: Agent hook smoke** — in a Claude Code session in the repo, ask it to run `terraform apply`; expected: blocked with the guardrails message.

- [ ] **Step 8: Ledger + README status line** → "Phase 0b done".

---

## Self-review notes

- Spec coverage: tiers (T2), verdict parsing (T3), labels/auto-merge/alerts (T4), notify action + ping + main-red (T1, T5), infra-aws alerts (T5), STOP rules (T5), `.claude` deny + hook (T6), repo settings + e2e (T7). Fork PRs: guard classifies but never auto-merges (T4 Decide). Error handling: notify `continue-on-error` (T1), missing plan → High (T2), missing verdict → not clean (T3), stale labels stripped (T4).
- Names consistent across tasks: `guard-tier.sh` outputs `tier=`/`reasons=`; `guard-verdicts.sh` outputs `claude=`/`coderabbit=`/`suggested_fix=`; `guard-labels.sh` outputs `approved=`/`destroy_ok=`; workflow reads exactly those via `$GITHUB_OUTPUT`.
- Known limits: `workflow_run` supplies `pull_requests[]` only for same-repo PRs (forks are skipped by the job `if`); `gh run download` of another run's artifact needs `actions: read` (granted). The guard PR itself (High) must be merged by a human before `guard` becomes required — Task 7 order handles the chicken-and-egg.
