# Ned — project rules for Claude

Ned is a proactive personal chief-of-staff agent. Design: `docs/superpowers/specs/2026-09-18-ned-design.md`.

## Conventions
- Conventional commits (`feat|fix|refactor|docs|test|chore|perf|ci: …`). No attribution trailers.
- Terraform is applied from GitHub Actions (`infra-aws.yml` on `infra/envs/prod`, gated by environment `prod`). Sole exception: `infra/envs/bootstrap` is applied locally by the maintainer (chicken-and-egg for the OIDC roles).
- Three CI roles: `ned-github-terraform-read` (PR plans, no writes, `-lock=false`), `ned-github-terraform-plan` (dispatch plans on `main`: lock + stash), `ned-github-terraform` (apply, env `prod`; verifies the stashed plan's sha256).
- Terraform tests use `mock_provider "aws" {}` + `command = apply`; IAM policies are `jsonencode()` locals so tests can assert on them.
- All AWS resources are named `ned-*`. IAM is least-privilege and resource-scoped; `Resource: "*"` only for list/describe APIs.
- GitHub Actions pinned to a full commit SHA with a `# vX.Y.Z` comment (Dependabot keeps them current); each job declares the minimum `permissions`.
- Secrets never in git. Runtime secrets live in SSM under `/ned/`.
- Python 3.12 + FastAPI backend, Next.js dashboard, Postgres + pgvector (later phases).

## Review priorities (in order)
1. Security: leaked secrets, over-broad IAM/workflow permissions, unpinned actions.
2. Correctness bugs and spec drift from the design doc.
3. Over-engineering: unrequested abstractions, config for constants, speculative code.
4. Test hygiene: tests must assert real behavior; no warnings in output.
Skip formatting nits — pre-commit owns them.

## STOP conditions (reviewers)
Any of these in a PR means the verdict is `VERDICT: HUMAN REVIEW REQUIRED`, followed by a `Suggested fix:` line:
- IAM trust policies, permissions boundaries, or the CI role policy change
- wildcard (`*`) actions or resources added to any policy
- secrets, tokens, or credentials appear in the diff
- workflow `permissions` widen, an action loses its version pin, or a required check is removed
- tests are deleted or weakened; a check is disabled
- terraform plan destroys anything
- changes to `.github/workflows/guard.yml`, `.github/workflows/infra-aws.yml`, `.github/workflows/claude-review.yml`, `.github/actions/**`, `.github/scripts/**`, `.claude/**`, `CLAUDE.md`, `.coderabbit.yaml`
Otherwise end the review with `VERDICT: PASS`. The verdict line is machine-read by the guard check; always include exactly one.

## Rules for agents working in this repo
- Never merge, apply Terraform, force-push, or touch secrets/variables. Open a PR; the guard check decides.
- Something unusual (drift, failing apply, unclear spec) → stop and say so in the PR; the human gets a Telegram alert.

## Engineering standards (this is a showcase repo)
- Structure: `infra/modules/<one purpose>` + `infra/envs/<env>` root configs; app code under `apps/<service>`; one responsibility per file; 200–400 lines typical.
- Reuse before writing: official or community-standard modules/libraries when they cover the need (e.g. terraform-aws-modules); custom code only for what is specific to Ned.
- Security by default: least privilege, pinned versions, secrets only in SSM/GitHub secrets, no `${{ }}` inside `run:` blocks, permissions boundaries on created principals.
- YAGNI and no repetition: no speculative abstractions; duplicated logic becomes a module/function.
- Every non-trivial change ships with a test and a doc line; refactors of live infra use `moved {}` blocks, never destroy/recreate.
