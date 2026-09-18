# Ned — project rules for Claude

Ned is a proactive personal chief-of-staff agent. Design: `docs/superpowers/specs/2026-09-18-ned-design.md`.

## Conventions
- Conventional commits (`feat|fix|refactor|docs|test|chore|perf|ci: …`). No attribution trailers.
- Terraform is applied only from GitHub Actions (`infra-aws.yml`, gated by environment `prod`). Never from a laptop.
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
