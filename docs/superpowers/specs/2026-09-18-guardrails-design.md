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
| **Low** | only paths under `apps/**`, `docs/**`, `tests/**`, `README.md`, `.github/dependabot.yml`; Dependabot minor/patch bumps; no deletions of files under `infra/**` or `.github/**` | auto-merge (squash) once all required checks are green and the PR is clean for its current head: Claude `VERDICT: PASS` (Dependabot PRs: Claude is skipped by design, not required) and CodeRabbit without findings on this head (no CodeRabbit review does not block: it needs a manual trigger on repos under 10 stars) | one-line silent digest when auto-merge is armed, once per head |
| **Medium** | `infra/aws/**` changes whose plan has adds/changes only; `.github/workflows/**` (except the guard and evidence workflows); Dependabot major bumps; `deploy/**`; any unclassified path; Claude `VERDICT: HUMAN REVIEW REQUIRED` | wait for label `human-approved` | alert with tier reasons, reviewer suggested fix, one-tap links |
| **High** | Terraform plan with ≥1 destroy; infra change with no plan; `infra/bootstrap/**`; `.github/workflows/guard.yml`, `.github/actions/**`, `.github/scripts/**`; the evidence producers `.github/workflows/infra-aws.yml` (plan text) and `.github/workflows/claude-review.yml` (verdict); `.claude/**`, `CLAUDE.md`, `.coderabbit.yaml`, `.github/CODEOWNERS`; deletions or renames out of `infra/**`/`.github/**`; force-push detected on the PR branch | blocked; needs `human-approved` (+ `allow-destroy` when destroys) | alert as Medium, marked HIGH |

The highest matching tier wins. Secrets are not a tier: gitleaks runs in pre-commit, so a hit fails `lint`, a required check, and blocks the merge on its own. Labels are created by the guard on first run (`tier:low|medium|high`, `human-approved`, `allow-destroy`, `needs-human`).

## Components

### 1. `guard` workflow (`.github/workflows/guard.yml`) — required status check
Triggers: `pull_request_target` (opened, synchronize, reopened, ready_for_review, labeled, unlabeled) and `workflow_run` of `claude-review` and `infra-aws` (completed). A `workflow_run` event evaluates nothing: its `rerun` job (permissions `contents: read`, `actions: write`) re-runs the latest `pull_request_target` guard run for that head, so the required check on the PR head is re-evaluated in place when a verdict or plan lands. Re-runs replay the original payload, so the label strip runs on the first attempt only.
Trust model: `pull_request_target` runs the base branch's (`main`'s) workflow and scripts with a write token. The job checks out `main` only (`persist-credentials: false`) and fetches the PR head as git objects (`git fetch origin refs/pull/<n>/head`) for diffing; it never checks out, sources, or executes a PR file. A PR therefore cannot change the gate that judges it.
Head binding: `HEAD_TIME` = earliest `created_at` of this workflow's `pull_request_target` runs for the head on this PR (server-set; runs linked to another PR are excluded; "now" if none). Every approval must be newer than it.
Steps:
1. PR facts (head, base, author, draft, fork, `HEAD_TIME`); comments and reviews fetched once.
2. Changed paths via `git diff --name-status --no-renames base...head`; force push = the event's `before` is gone or not an ancestor of the head, recorded with a marker comment so it stays sticky for that head.
3. For infra PRs, read the `plan-text` artifact of the completed `infra-aws` run for this head SHA; parse `Plan: A to add, C to change, D to destroy[, F to forget]`; D>0 → High; `destroys=D` is an output.
4. Reviewer verdicts (before classification): Claude counts only from `claude[bot]` (type `Bot`) with the comment written or updated after `HEAD_TIME`, and only on a line-anchored `VERDICT:` line; CodeRabbit counts only for a review whose `commit_id` is the head. Values: `claude=pass|human|missing`, `coderabbit=clean|findings|missing`. `human` raises the tier to at least Medium and its `Suggested fix:` goes into the alert.
5. Classify; apply labels; write a job summary.
6. Decision: Low + clean (see table) + not draft + not fork → `gh pr merge --auto --squash --match-head-commit <head>`; otherwise `gh pr merge --disable-auto` (no-op when not armed). An infra change without a plan for this head → exit 1 ("waiting for terraform plan") whatever the labels. Medium/High → exit 1 unless the required labels are valid; `allow-destroy` is required when `destroys > 0`.
7. Labels are valid only if the last `labeled` event is by a non-bot repo admin and newer than `HEAD_TIME`; otherwise the guard strips them. Every push also strips them (UX; the timestamp rule holds even if that step is cancelled).
8. On tier ≥ Medium → Telegram alert, once per head (marker comment written only after Telegram accepted the message). Markers count only in comments by `github-actions[bot]`.

### 2. Telegram notify action (`.github/actions/telegram-notify/action.yml`)
Composite action; inputs `message` (trusted HTML template with `{1}`…`{4}` placeholders), `arg1`…`arg4` (untrusted text: PR title, reasons, reviewer fix — fully HTML-escaped before substitution), `silent` (bool); output `sent` (`true` when Telegram accepted it). The final text is capped at 3900 characters. `curl` to `https://api.telegram.org/bot$TOKEN/sendMessage` with `chat_id`, `parse_mode=HTML`, `disable_notification`. Secrets passed by the caller. The composite never fails its caller (composite steps have no `continue-on-error`, so the run line swallows the failure and logs a warning). Used by: guard (alerts, digests; destroys are alerted here as tier High), infra-aws dispatch runs (apply waiting for approval; apply failed/succeeded), `main` red (push or dispatch run failed on `main`).

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
- `.claude/settings.json` `permissions.deny`: `terraform apply|destroy|import|state rm|state push|state mv|force-unlock|taint|untaint`, `gh pr edit`, `gh issue edit`, `gh api graphql`, `git push --force|-f`, `git reset --hard`, `git branch -D`, `rm -rf`, `gh pr merge`, `gh secret`, `gh variable set`, `gh api -X (DELETE|PUT|PATCH)`, `aws iam *`, `aws s3 rm|rb`, `aws ssm put-parameter|delete-parameter`, `aws sts assume-role`. `permissions.allow` for the read-only set used daily (`terraform fmt|validate|test|init`, `gh pr view|checks|diff`, `aws sts get-caller-identity`, `git status|log|diff`).
- `.claude/hooks/pre-tool-guard.sh` (PreToolUse on Bash): splits the command into segments (`;`, `&&`, `||`, `|`, `&`, newline, `$(`, backticks), strips wrappers (`VAR=val`, `env`, `command`, `sudo`, `xargs`, `bash -c '…'`, …) and then all quotes, and matches rules only at a segment's start, case-insensitively (except `git branch -D`, so `-d` passes) — so text inside commit messages or PR bodies never matches. Rules: the deny list above plus label edits (`gh pr|issue edit --add-label`, `gh api …/labels` with a mutating method or `-f/-F/--input`), merges (`gh api …/merge(s)`), `gh api graphql` unless every `-f query=` value is a `query` (mutations, `@file`, `--input` blocked), `gh api -X/--method DELETE|PUT|PATCH` in every form, `git push` with force/delete flags, `+ref`, `:ref` or `main` as the target, or a bare `git push [<remote>]` while on `main`, `rm` with recursive+force in any form, `aws s3api delete-*`; on block prints: "Blocked by Ned guardrails. Ask the human on Telegram; suggested safe alternative: …".
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
infra-aws (dispatch): apply pending prod ──► Telegram; apply result ──► Telegram
```

## Error handling
- Telegram unreachable: the composite never fails the caller, logs a warning and reports `sent=false`; the alert marker is not written, so the next run for the head retries; guard still blocks.
- Missing verdict (Claude skipped, e.g. fork, or not yet posted for this head): `claude=missing` in the alert; not clean → no auto-merge (Dependabot excepted).
- Plan artifact missing for an infra PR → tier High ("no terraform plan available").
- Label tampering: guard re-checks that `human-approved`/`allow-destroy` were added by a non-bot repo admin (event `labeled` actor) after `HEAD_TIME`; otherwise removes them. Pushes strip them too.

## Security
- The gate runs trusted code only (`pull_request_target`, `main` checkout, PR head read as objects). `infra-aws` PR plans run PR-authored Terraform, so that job holds only the OIDC role: no Telegram secrets and no write token (the plan comment is posted by a separate job that runs no PR code). PR plans run with `-lock=false` and only when `infra/` changes.
- Only humans can add `human-approved`/`allow-destroy` (guard verifies actor ≠ bot, permission = admin, and label newer than the head). Agents run with `.claude` deny-list + PreToolUse hook; CI tokens have no label-write except the guard job. `CODEOWNERS` names the gate's own paths (`.github/`, `.claude/`, `CLAUDE.md`, `.coderabbit.yaml`, `infra/bootstrap/`); enforcing code-owner review is a branch-protection setting.
- Third-party actions are pinned to full commit SHAs (`# vX.Y.Z` comment); Dependabot updates them.
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
