# Phase 0c: IaC Restructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-shape `infra/` into `infra/modules/*` + `infra/envs/*` using official `terraform-aws-modules` where they carry weight, with a zero-destroy migration of the live bootstrap and prod stacks.

**Architecture:** Three custom modules (`github-ci-role`, `bedrock-runtime`, `budget-alerts`) compose official modules (`iam-oidc-provider`, `iam-role`, `iam-user`, `sns`) with Ned-specific policy and resources. Two env roots (`bootstrap`, `prod`) hold only module calls, backend, provider, variables, and `moved {}` blocks that map every existing resource address to its new home. CI works from `infra/envs/prod`; module tests run in a matrix.

**Tech Stack:** Terraform ~> 1.14, aws ~> 6.65, tls ~> 4.0 (needed by iam-oidc-provider), terraform-aws-modules: s3-bucket 5.16.1, iam 6.8.2 (submodules), sns 7.1.1. Plain resources for budgets, log group, SSM, Bedrock logging (official wrappers are trivial there; see module READMEs).

**Spec:** `docs/superpowers/specs/2026-09-18-iac-restructure-design.md`. Module interface reference (confirmed from source): `docs/superpowers/specs/2026-09-18-module-interfaces.md`.

## Global Constraints

- Migration = `moved {}` only; acceptance for each env: `terraform plan` shows **0 to destroy** and **0 to add** except adds listed in the PR body (allowed: the bootstrap plan role and its inline policy; if the s3 module wants `aws_s3_bucket_ownership_controls`, set `control_object_ownership = false` or list it). In-place updates allowed only for the apply-role trust policy (narrowed to `environment:prod`, aud stays `StringEquals` — never `ForAllValues`), policy documents whose semantics are unchanged (SNS default statement), and tags.
- Names unchanged: role `ned-github-terraform` (set `use_name_prefix = false`), user `ned-runtime`, policies `ned-runtime-bedrock`, `ned-user-boundary`, `ned-role-boundary`, log group `/ned/bedrock`, topic `ned-budget-alerts`, budget `ned-monthly`, bucket `ned-tfstate-<acct>`.
- State keys unchanged: `bootstrap/terraform.tfstate`, `aws/terraform.tfstate` (documented in `infra/README.md`).
- Module rules: no provider blocks in modules; `versions.tf` with `required_providers` constraints; `README.md` per module (purpose, inputs, outputs, why-not-official where applicable); `tests/*.tftest.hcl` with `mock_provider "aws" {}` (+ `mock_provider "tls" {}` where used) and `command = apply`; variables validated; outputs minimal.
- Everything else from `CLAUDE.md` Engineering standards: least privilege, pinned versions, no `${{ }}` in `run:`, conventional commits, no attribution lines.
- Never run `terraform plan/apply` against AWS from an agent session; bootstrap plan/apply is the maintainer's; prod plan/apply is CI's.

---

## File Structure

```
infra/
  README.md                          layout, conventions, add-a-module recipe, state keys, migration notes
  modules/
    github-ci-role/
      README.md versions.tf variables.tf main.tf policy.tf boundaries.tf outputs.tf
      tests/role.tftest.hcl
    bedrock-runtime/
      README.md versions.tf variables.tf main.tf logging.tf outputs.tf
      tests/runtime.tftest.hcl
    budget-alerts/
      README.md versions.tf variables.tf main.tf outputs.tf
      tests/budget.tftest.hcl
  envs/
    bootstrap/
      README.md versions.tf backend.tf variables.tf main.tf moved.tf outputs.tf
    prod/
      README.md versions.tf backend.tf variables.tf main.tf moved.tf outputs.tf
.github/workflows/infra.yml          renamed from infra-aws.yml; working-directory infra/envs/prod; module test matrix
.github/workflows/pre-commit.yml     (no change; terraform hooks pick up new dirs)
.tflint.hcl                          unchanged
```
`infra/bootstrap/` and `infra/aws/` are deleted in the same PR as the envs are added (Task 6), never earlier.

---

### Task 1: `infra/modules/github-ci-role`

**Files:** create the module files listed above.

**Interfaces:**
- Inputs: `name` (default `ned-github-terraform`), `plan_role_name` (default `ned-github-terraform-plan`), `github_repo` (owner/name), `github_owner_id` (number), `github_repo_id` (number), `state_bucket_arn`, `aws_region`, `account_id`, `tags`.
- Outputs: `role_arn`, `plan_role_arn`, `oidc_provider_arn`, `user_boundary_arn`, `role_boundary_arn`.
- Two roles (least privilege for PR code): **apply** role `ned-github-terraform` trusts only `repo:<subject>:environment:prod`; **plan** role `ned-github-terraform-plan` is read-only on `ned-*` resources (Get/List/Describe), reads state objects, writes `plans/*`, and trusts `repo:<subject>:pull_request` and `repo:<subject>:ref:refs/heads/main`. PR-authored Terraform therefore never runs with write credentials.
- Internal addresses later used by `moved`: `module.oidc_provider.aws_iam_openid_connect_provider.this[0]`, `module.role.aws_iam_role.this[0]`, `module.role.aws_iam_role_policy.inline[0]`, `aws_iam_policy.user_boundary`, `aws_iam_policy.role_boundary`.

- [ ] **Step 1: `versions.tf`**
```hcl
terraform {
  required_version = "~> 1.14"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.65" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}
```

- [ ] **Step 2: `variables.tf`** — the eight inputs above with descriptions; validations: `github_repo` matches `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`; ids `> 0`.

- [ ] **Step 3: `boundaries.tf`** — move the two `aws_iam_policy` resources from `infra/bootstrap/boundary.tf` verbatim (names `ned-user-boundary`, `ned-role-boundary`; resource names `user_boundary`, `role_boundary`), using `var.aws_region`/`var.account_id`.

- [ ] **Step 4: `policy.tf`** — a `locals { ci_statements = { … } }` map in the `inline_policy_permissions` object shape (sid, effect, actions, resources, condition list) carrying every statement from `infra/bootstrap/ci_role_policy.tf` (StateBucketList, StateObjects on `aws/*` and `plans/*`, NedIamCreateUserWithBoundary, NedIamCreateRoleWithBoundary, NedIamManage, NedIamAttachScopedPolicies, PassRoleToBedrockOnly, DenySelfModifyAndBoundaryRemoval, DenyBoundaryRemoval, DenyBoundaryPolicyEdits, Budgets, BedrockLoggingConfig, LogsDescribe, NedLogGroups, NedSns, NedSsmParams, SsmDescribe). Conditions become `condition = [{ test = "StringEquals", variable = "iam:PermissionsBoundary", values = [aws_iam_policy.user_boundary.arn] }]` etc. The self-Deny resource is `module.role.arn`? — no: that would be a cycle. Use the deterministic ARN `arn:aws:iam::${var.account_id}:role/${var.name}` for the self-deny statement.

- [ ] **Step 5: `main.tf`**
```hcl
module "oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "6.8.2"
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

module "role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.8.2"
  name                 = var.name
  use_name_prefix      = false
  max_session_duration = 3600
  # NOT enable_github_oidc: it writes `ForAllValues:StringEquals` on aud, which passes when the key is absent.
  # Explicit trust instead: StringEquals aud + StringLike sub. Verify the variable shape from the module source
  # (6.8.2 variables.tf) at implementation time; the shape below is the intent.
  trust_policy_permissions = {
    GithubOidc = {
      actions    = ["sts:AssumeRoleWithWebIdentity"]
      principals = [{ type = "Federated", identifiers = [module.oidc_provider.arn] }]
      condition = [
        { test = "StringEquals", variable = "token.actions.githubusercontent.com:aud", values = ["sts.amazonaws.com"] },
        { test = "StringLike", variable = "token.actions.githubusercontent.com:sub", values = ["repo:${local.subject}:environment:prod"] },
      ]
    }
  }
  create_inline_policy      = true
  inline_policy_permissions = local.ci_statements
  tags = var.tags
  depends_on = [module.oidc_provider]
}
```
`local.subject = "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"`. A second `module "plan_role"` (same source/version) uses the same trust shape with sub values `repo:${local.subject}:pull_request` and `repo:${local.subject}:ref:refs/heads/main`, and an inline read-only policy (`local.plan_statements`: `iam:Get*`/`iam:List*` on `ned-*` users/roles/policies, `logs:Describe*`, `sns:Get*`/`sns:List*`, `ssm:DescribeParameters`/`ssm:GetParameter*` metadata on `/ned/*`, `budgets:View*`, `bedrock:GetModelInvocationLoggingConfiguration`, `s3:GetObject` on `aws/*`, `s3:PutObject` on `plans/*`, `s3:ListBucket` on the state bucket).

- [ ] **Step 6: `outputs.tf`** — `role_arn = module.role.arn`, `plan_role_arn = module.plan_role.arn`, `oidc_provider_arn = module.oidc_provider.arn`, `user_boundary_arn`, `role_boundary_arn`.

- [ ] **Step 7: `tests/role.tftest.hcl`** — `mock_provider "aws" {}` and `mock_provider "tls" {}`; `mock_data "aws_caller_identity"`-style overrides are not needed (account id is an input). Runs (`command = apply`): boundary names; `module.role.aws_iam_role_policy.inline[0].policy` decoded contains Sids `DenySelfModifyAndBoundaryRemoval`, `DenyBoundaryPolicyEdits`, `NedIamCreateUserWithBoundary` with `iam:PermissionsBoundary` condition, `PassRoleToBedrockOnly` with `iam:PassedToService`; no `"Action":"*"`; apply-role trust policy (`module.role.aws_iam_role.this[0].assume_role_policy`) contains `repo:EITANPOD@164246517/ned@1376066666:environment:prod`, a `StringEquals` aud condition, and no `ForAllValues`; plan-role trust contains `:pull_request` and `:ref:refs/heads/main` and its policy has no `iam:Create*`/`Put*`/`Delete*`/`Attach*`. Note: with mock providers, `aws_iam_policy_document` data sources inside the official module return synthetic JSON — if assertions on `inline[0].policy` cannot see real content, assert on `local.ci_statements` via an `output` in a test-only `outputs` block instead, and record it in the README. (Mock providers fabricate data-source results; the plan accepts asserting the locals.)

- [ ] **Step 8: `README.md`** — purpose, inputs/outputs table, "official modules used", "why boundaries are plain resources" (iam-policy wrapper adds nothing), migration addresses.

- [ ] **Step 9:** `terraform init -backend=false && terraform fmt -check && terraform validate && terraform test` inside the module; `pre-commit run --all-files`. Commit `feat(infra): github-ci-role module (official iam modules, boundaries, least-priv policy)`.

---

### Task 2: `infra/modules/bedrock-runtime`

**Interfaces:** inputs `user_name` (default `ned-runtime`), `allowed_model_ids`, `allowed_inference_profile_ids`, `user_boundary_arn`, `role_boundary_arn`, `log_retention_days` (14), `ssm_prefix` (`/ned/runtime`), `aws_region`, `account_id`, `tags`. Outputs `user_name`, `ssm_key_id_param`, `ssm_secret_param`, `log_group_name`.
Addresses for `moved`: `module.user.aws_iam_user.this[0]`, `module.user.aws_iam_access_key.this[0]`, `module.user.aws_iam_user_policy_attachment.additional["bedrock"]`, `aws_iam_policy.invoke`, `aws_ssm_parameter.key_id`, `aws_ssm_parameter.secret`, `aws_cloudwatch_log_group.this`, `aws_iam_role.logging`, `aws_iam_role_policy.logging_write`, `aws_bedrock_model_invocation_logging_configuration.this`.

- [ ] **Step 1: `main.tf`**
```hcl
resource "aws_iam_policy" "invoke" {
  name   = "${var.user_name}-bedrock"
  policy = jsonencode({ … same statements as infra/aws/iam.tf … })
  tags   = var.tags
}

module "user" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-user"
  version = "6.8.2"
  name                 = var.user_name
  permissions_boundary = var.user_boundary_arn
  create_login_profile = false
  create_access_key    = true
  policies             = { bedrock = aws_iam_policy.invoke.arn }
  tags                 = var.tags
}

resource "aws_ssm_parameter" "key_id" {
  name  = "${var.ssm_prefix}/aws_access_key_id"
  type  = "String"
  value = module.user.access_key_id
  tags  = var.tags
}
resource "aws_ssm_parameter" "secret" {
  name  = "${var.ssm_prefix}/aws_secret_access_key"
  type  = "SecureString"
  value = module.user.access_key_secret
  tags  = var.tags
}
```
- [ ] **Step 2: `logging.tf`** — move `aws_cloudwatch_log_group` (resource name `this`), `aws_iam_role.logging` (`permissions_boundary = var.role_boundary_arn`), `aws_iam_role_policy.logging_write`, `aws_bedrock_model_invocation_logging_configuration.this` from `infra/aws/logging.tf`, parametrised.
- [ ] **Step 3:** variables/outputs/versions/README (why the logging role is a plain resource: service trust with `SourceAccount/SourceArn` conditions is one block; the `iam-role` module's `trust_policy_permissions` shape was not verified and adds no value here).
- [ ] **Step 4: `tests/runtime.tftest.hcl`** — port the three `infra/aws/tests/*.tftest.hcl` assertions for iam + logging (policy content via `aws_iam_policy.invoke.policy`, boundary on `module.user.aws_iam_user.this[0].permissions_boundary`, SSM types/names, log group retention, logging config text-only, trust conditions). Keep `mock_resource` overrides for ARN-validated attributes as today.
- [ ] **Step 5:** validate + test + pre-commit; commit `feat(infra): bedrock-runtime module (official iam-user, invoke policy, SSM, invocation logging)`.

---

### Task 3: `infra/modules/budget-alerts`

**Interfaces:** inputs `name` (`ned-monthly`), `topic_name` (`ned-budget-alerts`), `limit_usd` (10), `email`, `account_id`, `tags`. Outputs `topic_arn`, `budget_name`. Addresses: `module.topic.aws_sns_topic.this[0]`, `module.topic.aws_sns_topic_policy.this[0]`, `aws_budgets_budget.monthly`.

- [ ] **Step 1: `main.tf`**
```hcl
module "topic" {
  source  = "terraform-aws-modules/sns/aws"
  version = "7.1.1"
  name            = var.topic_name
  use_name_prefix = false
  topic_policy_statements = {
    budgets_publish = {
      sid     = "AllowBudgetsPublish"
      actions = ["sns:Publish"]
      principals = [{ type = "Service", identifiers = ["budgets.amazonaws.com"] }]
      condition  = [{ test = "StringEquals", variable = "aws:SourceAccount", values = [var.account_id] }]
    }
  }
  create_subscription = false
  tags = var.tags
}

#trivy:ignore:AVD-AWS-0095 (justification as today)
resource "aws_budgets_budget" "monthly" { … as infra/aws/budgets.tf, subscriber_sns_topic_arns = [module.topic.topic_arn] … }
```
(`enable_default_topic_policy` stays default; the resulting policy gains the module's owner statement — an in-place update, listed in the PR.)
- [ ] **Step 2:** variables/outputs/versions/README; `tests/budget.tftest.hcl` porting the budget tuple assertions and topic name.
- [ ] **Step 3:** validate + test + pre-commit; commit `feat(infra): budget-alerts module (official sns, monthly budget)`.

---

### Task 4: `infra/envs/bootstrap` with `moved` blocks

- [ ] **Step 1: `main.tf`**
```hcl
module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.16.1"
  bucket = var.state_bucket_name
  versioning = { enabled = true }
  server_side_encryption_configuration = { rule = { apply_server_side_encryption_by_default = { sse_algorithm = "AES256" } } }
  block_public_acls = true; block_public_policy = true; ignore_public_acls = true; restrict_public_buckets = true
  lifecycle_rule = [
    { id = "expire-plans", enabled = true, filter = { prefix = "plans/" }, expiration = { days = 1 }, noncurrent_version_expiration = { days = 1 } },
    { id = "purge-plan-delete-markers", enabled = true, filter = { prefix = "plans/" }, expiration = { expired_object_delete_marker = true } },
  ]
  #trivy:ignore:AVD-AWS-0132 (same justification as today, placed above the module block)
}

module "github_ci_role" {
  source           = "../../modules/github-ci-role"
  github_repo      = var.github_repo
  github_owner_id  = var.github_owner_id
  github_repo_id   = var.github_repo_id
  state_bucket_arn = module.state_bucket.s3_bucket_arn
  aws_region       = var.aws_region
  account_id       = data.aws_caller_identity.current.account_id
  tags             = local.tags
}
```
- [ ] **Step 2: `moved.tf`** — one `moved {}` per existing address (bucket, versioning, SSE, public block, lifecycle, OIDC provider, role, inline policy, two boundaries) to the addresses listed in Task 1 / the interface reference. Example: `moved { from = aws_iam_role.ci  to = module.github_ci_role.module.role.aws_iam_role.this[0] }`.
- [ ] **Step 3:** `backend.tf` (same partial S3 backend, key `bootstrap/terraform.tfstate`), `versions.tf` (aws + tls), `variables.tf`, `outputs.tf` (`ci_role_arn`, `state_bucket`, boundary ARNs), README (local apply runbook, moved from the root README).
- [ ] **Step 4 (maintainer, local):** `terraform init -reconfigure -backend-config=…` then `terraform plan` → must print `0 to destroy`; expected: adds limited to the new plan role and its inline policy, in-place updates limited to `aws_iam_role.this[0]` (trust policy form) and `aws_iam_openid_connect_provider.this[0]` (thumbprint list) and tags. Also record the inline policy **name** the official iam-role module uses for `aws_iam_role_policy.inline[0]`: if it differs from `ned-github-terraform`, the plan shows a replace of that policy — accept only if the replacement is create-before-destroy safe (the role never loses its policy mid-apply); otherwise pin the name via the module's inline-policy name input. Paste the plan summary into the PR. Apply after review.
- [ ] Commit `feat(infra): envs/bootstrap on official s3 + github-ci-role module, moved blocks`.

---

### Task 5: `infra/envs/prod` with `moved` blocks

- [ ] `main.tf`: `module "bedrock_runtime"` (inputs from variables; boundaries by deterministic ARN `arn:aws:iam::<acct>:policy/ned-user-boundary`), `module "budget_alerts"`. `moved.tf` for the 13 resources (list in Task 2/3). `backend.tf` key `aws/terraform.tfstate`. Variables as today (`allowed_model_ids`, `budget_email`, `budget_limit_usd`, `log_retention_days`). Outputs as today.
- [ ] Commit `feat(infra): envs/prod composed from modules, moved blocks`.

---

### Task 6: CI + repo wiring; delete old roots

- [ ] Plan job assumes `vars.AWS_TF_PLAN_ROLE_ARN` (new repo variable from `terraform output -raw plan_role_arn`); apply job keeps `vars.AWS_TF_ROLE_ARN`.
- [ ] Rename `.github/workflows/infra-aws.yml` → `infra.yml`; `defaults.run.working-directory: infra/envs/prod`; add to `check` a matrix job `module-tests` over `[github-ci-role, bedrock-runtime, budget-alerts]` running `terraform init -backend=false && terraform test` in `infra/modules/${{ matrix.module }}` (env indirection, no `${{ }}` in run). Trivy/tflint scan `infra`. Update `main-red.yml`/`guard.yml` workflow name references (`infra-aws` → `infra`) and branch-protection context name if the job id changes (keep job id `check`).
- [ ] `git rm -r infra/bootstrap infra/aws`; update `README.md` (runbook paths), `CLAUDE.md` (conventions line), `.github/dependabot.yml` (terraform directories: `/infra/envs/bootstrap`, `/infra/envs/prod`, `/infra/modules/*` — one entry per dir), `guard-tier.sh` path rules (`infra/envs/bootstrap/*` and `infra/modules/github-ci-role/*` High; `infra/**` Medium) + its tests.
- [ ] Commit `refactor(infra): modules/envs layout; ci works from envs/prod; remove flat roots`.

---

### Task 7: Migration + verification

- [ ] Open PR `phase0c` → `main` (tier High: touches bootstrap + guard paths). CI plan for `envs/prod` must show `0 to add, N to change (policy docs/tags only), 0 to destroy`; paste both plans (prod from the PR comment, bootstrap from the maintainer's local run) into the PR body.
- [ ] Maintainer applies bootstrap locally; human labels the PR; merge; dispatch `infra` apply; approve `prod`.
- [ ] Post-apply: CI plan (dispatch `plan`) shows `No changes`. Run the Phase 0 verification commands again (budget, logging, SSM, nova-micro allowed / nova-pro denied).
- [ ] Follow-up PR: delete `moved.tf` in both envs (state is consistent now); plan must be `No changes`.

## Self-review notes
- Spec coverage: layout ✔ (T1–T6); official modules ✔ (s3, oidc-provider, iam-role, iam-user, sns); custom modules ✔; zero-destroy migration ✔ (moved + acceptance); state keys unchanged ✔; CI ✔ (T6); tests ✔ per module; docs ✔.
- Known uncertainties to resolve at implementation: mock-provider visibility of official-module policy documents (T1 step 7 has a fallback); whether s3 module creates ownership controls by default (check `control_object_ownership` default; set explicitly); the SNS module's default owner statement (in-place update, listed).
