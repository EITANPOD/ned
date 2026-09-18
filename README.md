# Ned

Proactive personal chief-of-staff agent. Watches your mail, calendar and Slack, decides when to interrupt you, reaches you on Telegram. Learns from what you act on.

Design: [docs/superpowers/specs/2026-09-18-ned-design.md](docs/superpowers/specs/2026-09-18-ned-design.md)

## Status

Phase 0: infra bootstrap + AWS (Terraform via GitHub Actions). See [Infra](#infra).

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
