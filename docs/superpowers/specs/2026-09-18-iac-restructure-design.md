# Ned — IaC Restructure Design (Phase 0c, 2026-09-18)

## Context

Phase 0 delivered two flat Terraform root configs (`infra/bootstrap`, `infra/aws`) with hand-written resources. They work and are applied. Ned is also a showcase: the IaC must read like a reference layout — modules with one purpose each, environments as thin root configs, official community modules where they cover the need, tests per module, and a migration that never destroys or recreates a live resource.

Decisions:
- Layout: `infra/modules/<purpose>` + `infra/envs/<env>`; env roots contain only module calls, backend, provider, variables.
- Official modules (pinned, Dependabot-tracked): `terraform-aws-modules/s3-bucket/aws` (state bucket), `terraform-aws-modules/iam/aws//modules/iam-oidc-provider` and `//modules/iam-role` (GitHub OIDC), `terraform-aws-modules/sns/aws` (alert topic), `terraform-aws-modules/cloudwatch/aws//modules/log-group`. No official Budgets module → plain resource inside the custom module.
- Custom modules only for Ned-specific composition: `github-ci-role` (least-priv policy + boundaries; uses the official OIDC modules inside), `bedrock-runtime` (user, invoke policy, key → SSM, invocation logging), `budget-alerts` (SNS via official module + budget).
- Migration with `moved {}` blocks and, where a resource moves into an official module with a different address shape, `terraform state mv` executed in the same run (`bootstrap` locally, `prod` via the CI plan/apply). Acceptance: every plan reads `0 to add, 0 to change, 0 to destroy` after the moves (tags or harmless in-place updates allowed, listed explicitly in the PR).
- State keys unchanged (`bootstrap/terraform.tfstate`, `aws/terraform.tfstate`) to keep the CI role's S3 grant and the migration risk minimal; documented.

## Target layout

```
infra/
  modules/
    github-ci-role/        OIDC provider (official) + CI role (official iam-role, ID-pinned subject) + inline least-priv policy + user/role permissions boundaries
      main.tf variables.tf outputs.tf policy.tf boundaries.tf README.md tests/*.tftest.hcl
    bedrock-runtime/       IAM user + invoke policy (allowed models var) + access key → SSM + log group (official) + logging role + invocation logging config
    budget-alerts/         SNS topic (official) + budget with 3 notifications
  envs/
    bootstrap/             s3-bucket (official; versioning, SSE, public block, plans/ lifecycle) + module.github_ci_role; applied locally once
    prod/                  module.bedrock_runtime + module.budget_alerts; applied by CI
  README.md                layout, conventions, how to add a module/env
```

Conventions: every module has `README.md` (inputs/outputs via terraform-docs format), `versions.tf` with provider constraints, `tests/` with mock-provider tests, no provider blocks inside modules, tags via `default_tags` in envs, variables validated, outputs minimal.

## Migration plan (no recreation)

1. Build modules and envs on a branch; envs get `moved { from = aws_iam_user.runtime  to = module.bedrock_runtime.aws_iam_user.runtime }` etc. for every existing resource address.
2. Resources that become official-module resources (bucket, OIDC provider, CI role, SNS topic, log group): `moved` where addresses are deterministic; otherwise a documented `terraform state mv` list run before plan (bootstrap: locally; prod: as a one-off step in the CI plan job guarded by an input `state_moves=true`, executed with the CI role which already has state read/write).
3. CI plan on the PR must show no destroys; the guard's destroy check enforces it.
4. After apply, remove the `moved` blocks in a follow-up PR (or keep for one release; decide in plan).

## CI changes
- `infra-aws.yml` becomes `infra.yml` with `working-directory: infra/envs/prod`; `check` also runs `terraform test` in each module directory (matrix over `infra/modules/*`).
- tflint/trivy run over `infra/`.
- README runbook paths updated.

## Testing
- Module tests with `mock_provider` (as today) asserting policy content, names, boundaries, notification tuples.
- Env-level `terraform validate` + `terraform test` with mocked modules where feasible.
- Migration proof: plan output attached to the PR (guard/plan comment) showing zero destroys.

## Out of scope
- Oracle env (`infra/envs/oracle`) — Phase 8.
- GitHub App token for auto-merge fan-out — separate small phase if wanted.
