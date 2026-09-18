# Ned — Guardrails & Human-in-the-Loop Design (Phase 0b, 2026-09-18)

## Context

Ned's code is written mostly by AI agents (Claude Code sessions) and reviewed by AI reviewers (Claude Code Action, CodeRabbit). Phase 0 showed the failure modes: a CI role that could rewrite itself, plan files with secrets in public artifacts, a stray session committing to the working branch. Eitan wants independent automation for routine work and a hard stop plus a Telegram alert, with a suggested fix, whenever something unusual happens. Humans approve only the dangerous slice.

Decisions:
- Risk tiers decide what is automatic. **Low → auto-merge. Medium → alert + `human-approved` label. High → blocked + alert; destroys also need `allow-destroy`.**
- Mechanical gates first (no LLM can talk them down); LLM reviewers add reasoning and a suggested fix.
- One Telegram bot (`ned`) for alerts now, reused by Ned itself in Phase 1. Secrets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.
- Applies to `prod` keep the existing manual environment approval.

## Risk tiers (computed by the `guard` job, no LLM)

| Tier | Triggered by any of | Merge policy | Alert |
|---|---|---|---|
| **Low** | only paths under `apps/**`, `docs/**`, `tests/**`, `README.md`; Dependabot minor/patch bumps; no deletions of files under `infra/**` or `.github/**` | auto-merge (squash) once all required checks are green and both reviewer verdicts are clean | one-line digest after merge |
| **Medium** | `infra/aws/**` changes whose plan has adds/changes only; `.github/workflows/**` (except the guard/notify files); Dependabot major bumps; `deploy/**` | wait for label `human-approved` | alert with tier reasons, plan summary, reviewer suggested fix, one-tap links |
| **High** | Terraform plan with ≥1 destroy; `infra/bootstrap/**`; `.github/workflows/guard.yml`, `.github/actions/**`; `.claude/**`, `CLAUDE.md`, `.coderabbit.yaml`, `CODEOWNERS`; any file matching secret patterns (gitleaks hit); force-push detected on the PR branch | blocked; needs `human-approved` (+ `allow-destroy` when destroys) | alert as Medium, marked HIGH |

The highest matching tier wins. Labels are created by the guard on first run (`tier:low|medium|high`, `human-approved`, `allow-destroy`, `needs-human`).

## Components

### 1. `guard` workflow (`.github/workflows/guard.yml`) — required status check
Triggers: `pull_request` (opened, synchronize, reopened, ready_for_review, labeled, unlabeled) and `workflow_run` of `claude-review` and `infra-aws` (completed), so the verdict and plan are re-evaluated when they land.
Steps:
1. Compute changed paths (`gh pr diff --name-only`) and deletions; classify tier per table; Dependabot semver from PR title.
2. For infra PRs, read the latest `plan.txt` artifact from the `infra-aws` run for this head SHA; parse `Plan: A to add, C to change, D to destroy`; D>0 → High.
3. Read reviewer verdicts: Claude sticky comment must contain `VERDICT: PASS`; CodeRabbit's latest review must report `Actionable comments posted: 0` (or no review yet → not clean). A verdict `VERDICT: HUMAN REVIEW REQUIRED` forces at least Medium and carries its `Suggested fix:` block into the alert.
4. Apply labels; write a job summary.
5. Decision: Low + all clean → `gh pr merge --auto --squash`; Medium/High → exit 1 unless the required labels are present (labels can only be added by a human: the guard removes them if the head SHA changes after they were added).
6. On tier ≥ Medium (first time per head SHA) → Telegram alert via the notify action.

### 2. Telegram notify action (`.github/actions/telegram-notify/action.yml`)
Composite action; inputs `message` (HTML), `silent` (bool). `curl` to `https://api.telegram.org/bot$TOKEN/sendMessage` with `chat_id`, `parse_mode=HTML`, `disable_notification`. Secrets passed by the caller. Used by: guard (alerts, digests), infra-aws (plan has destroys; apply waiting for approval; apply failed/succeeded), `main` red (`workflow_run` failure on `main`), Dependabot weekly digest.

Alert format:
```
🛑 HIGH | PR #12 feat: add slack connector
Why: infra/bootstrap changed; plan destroys 1 (aws_iam_role.x)
Reviewer: HUMAN REVIEW REQUIRED — trust policy widened to *
Suggested fix: pin Principal to arn:aws:iam::…:role/ned-*
Approve: <label link>   PR: <url>
```

### 3. Reviewer STOP rules
`CLAUDE.md` gains a "STOP conditions" section. The Claude review verdict line is mandatory and machine-readable: `VERDICT: PASS` or `VERDICT: HUMAN REVIEW REQUIRED`, followed by `Suggested fix:` when not PASS. STOP conditions: IAM trust/boundary/CI-role changes; wildcard resources or actions; secrets or tokens in diff; workflow permission widening or unpinned actions; deletion of tests; disabling a check; Terraform destroys; changes to guard/notify/CLAUDE.md/.claude. `.coderabbit.yaml` path instructions mirror the list. Claude's prompt in `claude-review.yml` is updated to require the verdict line.

### 4. Agent-side guardrails (`.claude/` in repo)
- `.claude/settings.json` `permissions.deny`: `terraform apply|destroy|import|state rm`, `git push --force|-f`, `git reset --hard`, `git branch -D`, `rm -rf`, `gh pr merge`, `gh secret`, `gh variable set`, `gh api -X (DELETE|PUT|PATCH)`, `aws iam *`, `aws s3 rm|rb`, `aws ssm put-parameter|delete-parameter`, `aws sts assume-role`. `permissions.allow` for the read-only set used daily (`terraform fmt|validate|test|plan`, `gh pr view|checks|diff`, `aws sts get-caller-identity`, `git status|log|diff`).
- `.claude/hooks/pre-tool-guard.sh` (PreToolUse on Bash): regex block of the same list plus "edits under infra/bootstrap require a note"; on block prints: "Blocked by Ned guardrails. Ask the human on Telegram; suggested safe alternative: …".
- `.claude/CLAUDE.md` pointer in root `CLAUDE.md`: "agents: you never merge, apply, or touch secrets; you open PRs and let guard decide".

### 5. Repo settings (one-time, via `gh api`, documented in runbook)
- Allow auto-merge on the repo.
- Branch protection on `main`: required checks `lint`, `check`, `guard`; `required_linear_history`; dismiss stale approvals irrelevant (no PR reviews required — guard is the gate).
- Labels created by guard.

## Data flow
```
PR event ──► guard: tier (paths, plan.txt, verdicts) ──► labels + summary
                 │                                       │
                 ├── Low & clean ──► gh pr merge --auto ─┴─► Telegram digest
                 └── Medium/High ──► exit 1 until human labels ──► Telegram alert (+ suggested fix)
infra-aws: plan destroys ──► Telegram; apply pending prod ──► Telegram; apply result ──► Telegram
```

## Error handling
- Telegram unreachable: notify step never fails the workflow (`continue-on-error`), logs the failure; guard still blocks.
- Missing verdict (Claude skipped, e.g. fork): treated as not clean → no auto-merge, alert says "no Claude verdict".
- Plan artifact missing for an infra PR → tier High ("plan unavailable").
- Label tampering: guard re-checks that `human-approved` was added by a repo admin (event `labeled` actor) and after the current head SHA; otherwise removes it.

## Security
- Only humans can add `human-approved`/`allow-destroy` (guard verifies actor ≠ bot and permission = admin). Agents run with `.claude` deny-list; CI tokens have no label-write except the guard job.
- Telegram token only in GitHub secrets; never echoed; notify action masks it.
- Fork PRs never reach auto-merge (guard skips forks, as the plan job does).

## Testing
- `guard` classifier is a shell script `.github/scripts/guard-tier.sh` with a `bats`-free self-test: `tests/guard/run.sh` feeds fixture file lists + plan snippets and asserts tiers (runs in `pre-commit.yml`).
- Notify action tested with a `workflow_dispatch` "ping" input that sends "Ned guardrails online".
- End-to-end: after merge, open three PRs: docs-only (auto-merges), infra add-only (Medium alert, label, merges), a PR deleting a resource (High, blocked until both labels).

## Phases
- **0b.1** notify action + ping + `main`-red alert + Telegram secrets runbook.
- **0b.2** guard workflow + tier script + tests + labels + repo settings (auto-merge, required check).
- **0b.3** reviewer STOP rules (CLAUDE.md, claude-review prompt, coderabbit) + infra-aws hooks (destroy alert, apply pending/failed alerts).
- **0b.4** `.claude` settings + hook + agent rules.
Each phase = a Low/Medium PR that exercises the guard itself.
