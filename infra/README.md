# infra

Ned's AWS infrastructure as Terraform: reusable modules, composed by one root per environment.

## Layout

| Path | Kind | Applied by | State key |
|------|------|------------|-----------|
| `envs/bootstrap` | root | maintainer, locally (CI cannot authenticate before its roles exist) | `bootstrap/terraform.tfstate` |
| `envs/prod` | root | `.github/workflows/infra-aws.yml` (dispatch on `main`, env `prod`) | `aws/terraform.tfstate` |
| `modules/github-ci-role` | module | via `envs/bootstrap` | - |
| `modules/bedrock-runtime` | module | via `envs/prod` | - |
| `modules/budget-alerts` | module | via `envs/prod` | - |

Both roots use a partial S3 backend (`-backend-config=bucket=... -backend-config=region=...`) with
`use_lockfile`; the bucket is created by `envs/bootstrap`. Keep the state keys: the CI roles' S3 grants
are scoped to `aws/*` and `plans/*`.

## Conventions

- **Modules** (`modules/<one purpose>`): no backend, no provider config, only `required_providers`;
  `validation` on inputs with a known domain; wrap official `terraform-aws-modules` where they fit; `README.md` with inputs,
  outputs and design notes; `tests/*.tftest.hcl` with `mock_provider "aws" {}`. Modules do not commit
  `.terraform.lock.hcl` (gitignored); roots do.
- **Envs** (`envs/<env>`): `backend.tf`, `versions.tf` (provider + default tags), `variables.tf`,
  `main.tf` composing modules, `outputs.tf`. No resources that belong in a module.
- Every AWS name is `ned-*`; principals created by CI carry the `ned-user-boundary` / `ned-role-boundary`
  permissions boundaries (from `envs/bootstrap`).
- Refactors of live resources use `moved {}` blocks, never destroy/recreate.

## Add a module

1. `modules/<name>/` with `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `README.md`, `tests/`.
2. Call it from the env root; if it takes over live resources, add `moved {}` blocks there.
3. Add it to the `module-tests` matrix in `infra-aws.yml` and a `terraform` entry in `.github/dependabot.yml`.
4. If the apply role needs new permissions, change `modules/github-ci-role` (High tier; re-apply
   `envs/bootstrap` locally before merging the PR that needs them).

## CI roles

Created by `modules/github-ci-role` (details and rationale in its README).

| Job | Trigger | Role (repo variable) | S3 access |
|-----|---------|----------------------|-----------|
| `plan` | `pull_request` (same-repo, `infra/` changed) | `ned-github-terraform-read` (`AWS_TF_READ_ROLE_ARN`) | read state; `-lock=false`; no stash |
| `plan` | `workflow_dispatch` on `main` | `ned-github-terraform-plan` (`AWS_TF_PLAN_ROLE_ARN`) | read state, lock, write `plans/<run_id>.tfplan` |
| `apply` | dispatch `action=apply`, env `prod` approval | `ned-github-terraform` (`AWS_TF_ROLE_ARN`) | state rw, read the stash |

A dispatch plan stashes the tfplan only for `action=apply` with changes, and exports its sha256 as a job
output; `apply` fails unless the fetched stash matches it. `check` (fmt, validate, tflint, trivy) and `module-tests (<module>)` (`terraform test`
per module) run on every PR; `module-tests` is not yet a required check (add it to branch protection
once it has run on `main`).

## Prerequisites

- Environment `prod`: required reviewer + deployment branch policy `protected_branches: true`, with `main`
  the only protected branch. The apply role trusts `environment:prod` regardless of ref, so this policy is
  what keeps applies on `main` (snippet in the root README runbook).
- Repo variables `AWS_TF_READ_ROLE_ARN`, `AWS_TF_PLAN_ROLE_ARN`, `AWS_TF_ROLE_ARN`, `TF_STATE_BUCKET`,
  `AWS_REGION`, `BUDGET_EMAIL`. A missing role variable fails the plan job with an explicit error.

## Migration from the flat roots (Phase 0c)

`infra/bootstrap` -> `envs/bootstrap` and `infra/aws` -> `envs/prod`, same state keys, every address
mapped by `moved.tf` (tables in each env README). Rollout order:

1. Merge any open infra PR.
2. Maintainer applies `envs/bootstrap` locally: creates the plan and read roles, narrows the apply-role
   trust to `environment:prod` (this breaks the old PR-plan path, hence step 1). From here until step 5,
   `main`'s old dispatch plan/apply cannot run either (its plan job assumes the apply role outside `prod`).
   Never run Terraform in the old `infra/bootstrap` config again: the bootstrap state now has module
   addresses, and the old config would plan to destroy and recreate everything.
3. Set repo variables `AWS_TF_PLAN_ROLE_ARN` and `AWS_TF_READ_ROLE_ARN` from the bootstrap outputs.
4. CI on the Phase 0c PR plans `envs/prod` with the read role: expect 0 to add, 1 to change (SNS topic
   policy `Sid`), 0 to destroy.
5. Merge.
6. Dispatch `infra-aws` on `main` with `action=apply`, approve `prod`.
7. Follow-up PR removes the `moved.tf` files after a clean `No changes` plan.
