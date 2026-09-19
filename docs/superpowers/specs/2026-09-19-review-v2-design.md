# Review v2: one reviewer, Telegram decisions — design

Status: draft for maintainer review · 2026-09-19 · replaces the tier/label gate of `2026-09-18-guardrails-design.md`

## Why

The Phase 0b gate pages the maintainer for noise (PR #4: a variable description under `infra/` was "medium").
Tiers are path-based, reviews come from two bots (Claude on Haiku + CodeRabbit), and approval means adding a
GitHub label by hand. The maintainer wants: one trustworthy reviewer, auto-merge when it is clean, and every
decision the reviewer cannot make delivered to Telegram with buttons.

## Behaviour

```
PR opened / updated (non-draft)
  └─ Claude review (Sonnet 5): VERDICT PASS|FAIL, WHY, FIX (or none)
       ├─ PASS, no hard-floor hit  → auto-merge (squash, pinned to head SHA); silent 🟢 note
       ├─ PASS, hard-floor hit     → 📩 reason            [✅ Approve & merge] [❌ Deny]
       ├─ FAIL, FIX given          → 📩 WHY + FIX         [🔧 Fix it] [✅ Approve & merge] [❌ Deny]
       └─ FAIL, no FIX             → 📩 WHY               [✅ Approve & merge] [❌ Deny]
🔧 Fix it   → Claude commits FIX to the PR branch → full re-run (checks + review) → top. Max 2 rounds per PR;
              after that the message offers only Approve / Deny.
✅ Approve  → approval recorded for that head SHA → gate passes → auto-merge armed (lint/check must be green).
❌ Deny     → PR closed with comment "denied via Telegram".
```

Invariants:
- Every button carries the PR number and the head SHA it was sent for. If the head moved, the tap is a no-op and
  the bot answers "PR changed — a new review is coming".
- Only the maintainer's Telegram user id can act; other taps are answered "not authorised" and ignored.
- At most one Telegram message per head SHA (existing `guard-marked.sh` marker pattern).
- Any push invalidates earlier approvals (approval is bound to the SHA, not the PR).
- Dependabot: Claude does not run on Dependabot PRs (no secrets there). Patch/minor bumps auto-merge once
  `lint`/`check` are green; majors send the Approve/Deny message. Dependabot is exempt from the path floor
  (author `dependabot[bot]` is server-set).

### Hard floor (always asks, even on PASS)

1. The review system itself: `.github/**` (except `.github/dependabot.yml`), `CLAUDE.md`, `.claude/**`,
   `infra/modules/telegram-approver/**`. Otherwise one PR could weaken its reviewer and later PRs pass unchecked.
2. A Terraform plan that destroys anything (parsed from the PR's plan artifact, as today). An `infra/` change with
   no plan yet keeps the gate pending (no merge, no message) until the plan lands.

Everything else is Claude's call. IAM changes outside the floor are reviewed by Claude, not by a path rule.

## Review rules (what FAIL means)

Claude (model `claude-sonnet-5`, via the existing `CLAUDE_CODE_OAUTH_TOKEN`) FAILs only for:
security problems (leaked secrets, over-broad IAM/workflow permissions, unpinned actions, `${{ }}` in `run:`),
correctness bugs, behaviour that contradicts the design spec, deleted/weakened tests or disabled checks, and
Terraform that runs code at plan time (`external` data sources, provisioners, new/changed provider or module
`source`). Everything else (style, wording, naming, over-engineering opinions, docs) is at most a non-blocking
bullet under PASS.

Output contract (one sticky comment, machine-read, last matching line wins):
```
VERDICT: PASS | FAIL
WHY: <one sentence, required on FAIL>
FIX: <concrete change> | none
```
`CLAUDE.md` "STOP conditions" is replaced by these rules; the path-based items move to the mechanical floor.

## Components

| Unit | Purpose | Runs as |
|---|---|---|
| `.github/workflows/claude-review.yml` | review on `pull_request` + `workflow_dispatch(pr)`; Sonnet 5; posts verdict | `GITHUB_TOKEN` (read + PR comment) |
| `.github/workflows/guard.yml` (job name `guard` kept: it is a required check) | `pull_request_target` + `workflow_run`; reads verdict/approval for head, floor check, arms auto-merge or sends Telegram with buttons | main's copy only; `GITHUB_TOKEN` |
| `.github/scripts/guard-floor.sh` (replaces `guard-tier.sh`) | changed paths + plan → `floor=none|<reasons>` | pure bash, unit-tested |
| `.github/scripts/guard-verdicts.sh` (simplified) | parse `VERDICT/WHY/FIX` for head; CodeRabbit removed | pure bash, unit-tested |
| `.github/scripts/guard-approval.sh` (replaces `guard-labels.sh`) | approved for this head? = label `human-approved` added after head arrived by a repo admin **or** by the Ned app bot | pure bash, unit-tested |
| `.github/workflows/telegram-action.yml` | `workflow_dispatch(action, pr, sha)`; re-checks head == sha; approve → label as app bot; deny → close; fix → run Claude fixer (Sonnet 5), push with app token (so checks re-run), round counter via marker comments | main's copy; GitHub App installation token |
| `.github/actions/telegram-notify` | gains optional inline-keyboard `buttons` input | composite action |
| `infra/modules/telegram-approver` | Lambda (Python 3.12, stdlib only) + Function URL: verifies Telegram secret header and user id, maps `callback_data` → `workflow_dispatch` of `telegram-action.yml`, answers the tap | terraform-aws-modules/lambda |

Removed: CodeRabbit (`.coderabbit.yaml`, verdict parsing, README section), tiers, `allow-destroy`, tier labels.

### Telegram → GitHub path (security)

- Telegram webhook → Lambda Function URL (auth `NONE`; Telegram cannot sign requests). Lambda rejects any request
  without the `X-Telegram-Bot-Api-Secret-Token` equal to the SSM value (constant-time compare), then any
  `callback_query.from.id` ≠ approver id. `callback_data` = `<a|d|f>:<pr>:<40-hex sha>`, strictly regex-validated.
- Lambda's GitHub credential: fine-grained PAT, this repo only, **Actions: write** only (can dispatch workflows, cannot
  push code, label or merge). Everything else happens inside `telegram-action.yml`, which runs main's reviewed code.
- `telegram-action.yml` uses a GitHub App ("ned-bot", this repo only: contents, pull requests, issues write) via
  `actions/create-github-app-token`. App pushes trigger workflows (a `GITHUB_TOKEN` push would not re-run checks),
  and PR-authored workflows cannot impersonate the app, so an app-added label is a trustworthy approval record.
  This is the agent identity deferred in Phase 0 — now needed.
- Secrets: SSM `/ned/telegram/bot-token`, `/ned/telegram/webhook-secret`, `/ned/github/dispatch-token`
  (SecureString, created by the maintainer, never in Terraform state); `/ned/telegram/approver-id` (String).
  App private key and id: GitHub environment `ned-bot` (deployment branch policy restricted to `main`),
  secret `NED_APP_PRIVATE_KEY` and variable `NED_APP_ID` — a branch workflow could otherwise mint an app
  token and forge an approval. `NED_APP_SLUG` stays a repo variable (not secret; the guard needs it too).
- Lambda IAM: `ssm:GetParameter(s)` on exactly those ARNs + `kms:Decrypt` via `aws/ssm` condition; logs. Reserved
  concurrency 2 (caps abuse; free tier: 1M requests/month).
- Branch protection unchanged: required checks `lint`, `check`, `guard`; `enforce_admins`. Nothing bypasses `guard`.

## Error handling

- Telegram send fails → no marker written → next guard run for that head retries (existing behaviour).
- Lambda cannot dispatch → answers the tap "failed, try again" and logs; no state changes.
- Fixer produces no diff or checks fail → round still counts; next review message shows the new state.
- Stale tap (head moved, PR closed/merged) → no-op with an explanatory answer.

## Testing

- bash unit tests in `tests/guard/` for floor, verdicts, approval, callback-data parsing (existing harness).
- Lambda: `python -m unittest` with Telegram/GitHub calls stubbed (auth header, user id, stale-data, dispatch payload).
- Terraform module test (`mock_provider`, `command = apply`) asserting the Lambda policy is scoped to the 4 ARNs.
- E2E on real PRs: (a) docs PR → auto-merge; (b) PR with a planted bug → FAIL+FIX → Fix it → merge;
  (c) `.github` edit → floor message → Approve; (d) Deny closes; (e) stale tap after push is a no-op.

## Rollout

1. Merge PR #5 (Phase 0c) first; this branches from it.
2. PR A — `infra/modules/telegram-approver` + wiring in `envs/prod`; applied via `infra-aws` (prod approval).
3. Maintainer: create GitHub App + PAT, put SSM values and GitHub secret/variable, run `setWebhook` (runbook in
   the module README). These are human-only steps (secrets).
4. PR B — gate rewrite (review, guard, telegram-action, notify buttons, CodeRabbit removal). Judged by the old
   guard (high tier → `human-approved` label), after which the new flow is live.
5. E2E tests (a)–(e).

## Out of scope

Free-text replies to the bot, approving from anything but buttons, multiple approvers, the Phase 1 Ned bot
(it may later absorb the Lambda's job).
