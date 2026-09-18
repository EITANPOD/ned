# Ned — project rules for Claude

Ned is a proactive personal chief-of-staff agent. Design: `docs/superpowers/specs/2026-09-18-ned-design.md`.

## Conventions
- Conventional commits (`feat|fix|refactor|docs|test|chore|perf|ci: …`). No attribution trailers.
- Terraform is applied from GitHub Actions (`infra-aws.yml`, gated by environment `prod`). Sole exception: `infra/bootstrap` is applied locally, once, by the maintainer (chicken-and-egg for the OIDC role).
- Terraform tests use `mock_provider "aws" {}` + `command = apply`; IAM policies are `jsonencode()` locals so tests can assert on them.
- All AWS resources are named `ned-*`. IAM is least-privilege and resource-scoped; `Resource: "*"` only for list/describe APIs.
- GitHub Actions pinned to major tags; each job declares the minimum `permissions`.
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
- changes to `.github/workflows/guard.yml`, `.github/actions/**`, `.github/scripts/**`, `.claude/**`, `CLAUDE.md`, `.coderabbit.yaml`
Otherwise end the review with `VERDICT: PASS`. The verdict line is machine-read by the guard check; always include exactly one.

## Rules for agents working in this repo
- Never merge, apply Terraform, force-push, or touch secrets/variables. Open a PR; the guard check decides.
- Something unusual (drift, failing apply, unclear spec) → stop and say so in the PR; the human gets a Telegram alert.
