# Ned

Proactive personal chief-of-staff agent. Watches your mail, calendar and Slack, decides when to interrupt you, reaches you on Telegram. Learns from what you act on.

Design: [docs/superpowers/specs/2026-09-18-ned-design.md](docs/superpowers/specs/2026-09-18-ned-design.md)

## Status

Phase 0 (infra bootstrap + AWS runtime via Terraform in GitHub Actions) and Phase 0b (guardrails: risk-tiered `guard` gate, reviewer verdicts, Telegram alerts, agent deny-list) are live. Next: Phase 0c, IaC restructure into `infra/modules` + `infra/envs`. See [Infra](#infra).

## Infra

All Terraform runs in GitHub Actions, with one exception: `infra/bootstrap` is applied from a laptop once (see runbook) because CI cannot authenticate before the OIDC role exists.

| Root module        | State key                     | Trigger                                   |
|--------------------|-------------------------------|-------------------------------------------|
| `infra/bootstrap`  | `bootstrap/terraform.tfstate` | local, one time (see runbook) |
| `infra/aws`        | `aws/terraform.tfstate`       | PR → plan comment; manual dispatch → apply (gated by env `prod`) |

Local checks only: `pre-commit run --all-files`, `terraform test` (mock provider, no creds).

### PR review bots

Every non-draft PR gets two automated reviews:
- **Claude Code Action** (`claude-review.yml`) — reads `CLAUDE.md`, posts one sticky verdict comment + inline defects. Auth: `CLAUDE_CODE_OAUTH_TOKEN` secret from `claude setup-token` (Pro/Max subscription).
- **CodeRabbit** — free on public repos, config in `.coderabbit.yaml`.
Dependabot PRs are skipped by Claude (no secrets on those runs).
CodeRabbit only auto-reviews repos with 10+ stars; below that, comment `@coderabbitai review` on the PR to trigger it.

### Guardrails (guard check)

Every PR gets a risk tier from `.github/scripts/guard-tier.sh` (paths, terraform plan destroys, Dependabot semver, force-push, a Claude `HUMAN REVIEW REQUIRED` verdict). `guard` runs on `pull_request_target`: it always executes `main`'s copy of the workflow and scripts, and only reads the PR head as git objects, so a PR cannot change the gate that judges it.

| Tier | Merge | You get |
|---|---|---|
| low | auto-merge once `lint`, `check`, `guard` are green, Claude posted `VERDICT: PASS` on this head (Dependabot: skipped) and CodeRabbit has no findings on this head | silent Telegram digest (once per head) |
| medium | blocked until you add label `human-approved` | Telegram alert with reasons + reviewer's suggested fix |
| high | blocked until `human-approved` (+ `allow-destroy` for destroys) | same, marked HIGH |

Labels only count when added by a repo admin after the current head was pushed (GitHub's own timestamps: the label event vs. the first guard run for that head on the PR); any push also strips `human-approved` and `allow-destroy`. With `strict: true` branch protection, "Update branch" is a push too, so it needs a fresh `human-approved`. In short: after **any** push, re-add `human-approved` (and `allow-destroy`) once you have reviewed the new head; an older label never carries over, even if the strip is skipped. Agents cannot add or remove labels: the `.claude` hook blocks `gh pr|issue edit --add-label/--remove-label` and label writes through `gh api`.

Reviewer verdicts are machine-read and bound to the current head: Claude (`claude[bot]` only) must post `VERDICT: PASS` or `VERDICT: HUMAN REVIEW REQUIRED` + `Suggested fix:` after the head was pushed; CodeRabbit counts only for a review of this exact commit. CodeRabbit with no review does not block Low (it needs a manual `@coderabbitai review` below 10 stars); CodeRabbit with findings does. A Low PR that stops being clean has auto-merge disabled.

Known limitation, agent identity: agent sessions currently use the maintainer's GitHub login (an admin), so the label check cannot tell an agent from the maintainer. Mitigations in place: the `.claude` hook and deny-list block label edits, merges and pushes to `main` from agent sessions, and branch protection runs with `enforce_admins`. A dedicated GitHub App identity is planned for when agents run unattended.

Known limitation: auto-merged PRs do not trigger `push` workflows on `main` (GitHub does not fan out events from `GITHUB_TOKEN`). The PR's own checks are the verification; `main-red` covers manual dispatches. A GitHub App token can lift this later.

One-time setup: secrets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (create the bot with @BotFather, `/start` it, read your chat id from `getUpdates`); enable auto-merge on the repo; add `guard` to the required checks. `app_id` 15368 is GitHub Actions, so only Actions runs can satisfy `lint`/`check`/`guard` (a commit status with the same name from anyone else does not count); `enforce_admins` makes the gate apply to admins too:

```bash
gh api -X PATCH repos/<owner>/<repo> -f allow_auto_merge=true
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'EOF'
{"required_status_checks":{"strict":true,"checks":[{"context":"lint","app_id":15368},{"context":"check","app_id":15368},{"context":"guard","app_id":15368}]},"enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false,"required_linear_history":true}
EOF
```
Test the bot: Actions → `telegram-ping` → Run.

### First-time bootstrap runbook

Bootstrap is the one Terraform module applied from a laptop, once, because CI cannot authenticate before the OIDC role exists. It creates: the state bucket, the GitHub OIDC provider, and the CI role `ned-github-terraform`.

1. Repo variables: `AWS_ACCOUNT_ID`, `AWS_REGION=us-east-1`, `TF_STATE_BUCKET=ned-tfstate-<account-id>`, `BUDGET_EMAIL=<you>`.
2. Local, with your admin profile. Get the ids with `gh api repos/<owner>/<repo> -q '.owner.id, .id'`.

   ```bash
   cd infra/bootstrap
   printf 'terraform {\n  backend "local" {}\n}\n' > zz_local_override.tf
   export AWS_PROFILE=<admin-profile> TF_VAR_github_repo=<owner>/<repo> TF_VAR_github_owner_id=<owner-id> TF_VAR_github_repo_id=<repo-id> TF_VAR_aws_region=us-east-1 TF_VAR_state_bucket_name=ned-tfstate-<account-id>
   terraform init -reconfigure && terraform apply
   rm zz_local_override.tf
   terraform init -migrate-state -force-copy -backend-config="bucket=$TF_VAR_state_bucket_name" -backend-config="region=$TF_VAR_aws_region"
   rm -f terraform.tfstate terraform.tfstate.backup
   ```

3. Set repo variable `AWS_TF_ROLE_ARN` from `terraform output -raw ci_role_arn`. Re-apply `infra/bootstrap` locally whenever it changes (same commands, no override file needed once state is in S3).
4. Create environment `prod` with yourself as required reviewer. Branch protection on `main`: require PR + `lint` and `check` status checks.
5. Open a PR touching `infra/aws/` → plan appears as a PR comment. Merge.
6. Actions → `infra-aws` → Run workflow with `action=apply` → approve the `prod` deployment → resources created. If it fails on the Bedrock logging configuration with an IAM validation error, re-run the apply once (IAM propagation).

Runtime credentials for Ned are in SSM: `/ned/runtime/aws_access_key_id`, `/ned/runtime/aws_secret_access_key` (SecureString). They are reserved for the Phase 8 deploy job; nothing reads them yet.
