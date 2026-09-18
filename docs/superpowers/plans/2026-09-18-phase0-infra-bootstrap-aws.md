# Phase 0: Infra Bootstrap + AWS Terraform + Pipelines — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Ned repo with DevOps hygiene, Terraform remote state + GitHub OIDC (bootstrap), and the AWS runtime stack (least-priv Bedrock IAM user, invocation logging, $5/$10 budgets), all planned/applied only from GitHub Actions.

**Architecture:** Two Terraform root modules. `infra/bootstrap` (S3 state bucket w/ native lockfile, GitHub OIDC provider, CI role) is applied once by a `workflow_dispatch` job using temporary bootstrap keys, then migrates its own state into the bucket. `infra/aws` (runtime IAM user + policy, key stored in SSM SecureString, Bedrock logging, budgets + SNS) is planned on PRs and applied only via manual dispatch gated by GitHub environment `prod` with a required reviewer. Terraform unit tests use `mock_provider` so they run with zero credentials.

**Tech Stack:** Terraform 1.14 (S3 backend `use_lockfile`, `terraform test` + `mock_provider`), AWS provider ~> 6.65, tflint v0.64 + aws ruleset v0.48, trivy config scan, pre-commit (terraform fmt/validate, gitleaks v8.30.1, pre-commit-hooks v6), GitHub Actions (checkout v7, setup-terraform v4, configure-aws-credentials v6, setup-tflint v6, trivy-action v0.36), Dependabot.

**Spec:** `docs/superpowers/specs/2026-09-18-ned-design.md` (sections "Infrastructure as Code", "Intelligence: model routing", "Security").

## Global Constraints

- Terraform is **never applied from a laptop**. Local runs allowed: `terraform fmt`, `validate`, `test` (mock provider), `pre-commit`. No `plan`/`apply` locally.
- AWS region: `us-east-1`. AWS account used: profile `eitan` (personal). Account ID lives in GitHub variable `AWS_ACCOUNT_ID`, never committed.
- All AWS resource names prefixed `ned-`. CI role may only manage `ned-*` resources.
- Budget: monthly COST budget limit **10 USD**; alerts at **50% actual (=$5)**, **100% actual**, **100% forecasted**.
- Default runtime model: `amazon.nova-micro-v1:0` (cheapest, verified 2026-09-18). Allowed model list is a variable; user can extend.
- Bedrock invocation logs: CloudWatch group `/ned/bedrock`, retention **14** days, text only (no embedding/image/video data).
- Secrets never committed. Runtime access key secret goes to SSM SecureString `/ned/runtime/aws_secret_access_key` (accepted: value also lives in encrypted, private, versioned state bucket).
- Conventional commits (`feat|fix|refactor|docs|test|chore|perf|ci: …`). Plain commit messages, no attribution lines.
- Every GitHub Action pinned to a major tag listed above. Dependabot keeps them fresh.
- Repo: `EITANPOD/ned`, **public** (portfolio + environment protection rules are free on public repos).

---

## File Structure

```
ned/
  .editorconfig
  .pre-commit-config.yaml
  .tflint.hcl
  .github/
    CODEOWNERS
    dependabot.yml
    pull_request_template.md
    workflows/
      pre-commit.yml          lint everything on PR
      infra-bootstrap.yml     workflow_dispatch only, one-time
      infra-aws.yml           PR: fmt/validate/tflint/trivy/plan+comment; dispatch: plan→gated apply
  infra/
    bootstrap/
      versions.tf             terraform + provider pins, partial S3 backend block
      variables.tf            github_repo, aws_region, state_bucket_name
      main.tf                 state bucket (+versioning, SSE, public block), OIDC provider, CI role
      ci_role_policy.tf       least-priv policy document for the CI role
      outputs.tf              ci_role_arn, state_bucket
      tests/bootstrap.tftest.hcl
    aws/
      versions.tf             pins + partial S3 backend block
      variables.tf            aws_region, allowed_model_ids, budget_email, budget_limit_usd, log_retention_days
      iam.tf                  ned-runtime user, access key, SSM param, bedrock invoke policy
      logging.tf              log group, bedrock logging role, invocation logging config
      budgets.tf              SNS topic + policy, budget with 3 notifications
      outputs.tf              runtime_user_name, ssm_secret_param_name, log_group_name, sns_topic_arn
      tests/iam.tftest.hcl
      tests/logging.tftest.hcl
      tests/budgets.tftest.hcl
  README.md                   phase-0 sections: bootstrap runbook, how infra pipelines work
```

---

### Task 1: Repo hygiene (pre-commit, editorconfig, Dependabot, CODEOWNERS, PR template)

**Files:**
- Create: `.editorconfig`, `.pre-commit-config.yaml`, `.tflint.hcl`, `.github/CODEOWNERS`, `.github/dependabot.yml`, `.github/pull_request_template.md`, `.github/workflows/pre-commit.yml`
- Modify: `README.md` (create)

**Interfaces:**
- Produces: `.tflint.hcl` at repo root, used by `infra-aws.yml` via `tflint --config "$(pwd)/.tflint.hcl"`.

- [ ] **Step 1: Install local lint tools (one-time, laptop)**

```bash
brew install pre-commit tflint trivy
```
Expected: all three on PATH (`pre-commit --version`, `tflint --version`, `trivy --version`).

- [ ] **Step 2: Write `.editorconfig`**

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.py]
indent_size = 4

[Makefile]
indent_style = tab
```

- [ ] **Step 3: Write `.pre-commit-config.yaml`**

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
      - id: check-merge-conflict
      - id: detect-private-key
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.109.1
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
        args:
          - --hook-config=--retry-once-with-cleanup=true
          - --tf-init-args=-backend=false
      - id: terraform_tflint
        args:
          - --args=--config=__GIT_WORKING_DIR__/.tflint.hcl
```

- [ ] **Step 4: Write `.tflint.hcl`**

```hcl
config {
  call_module_type = "all"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

- [ ] **Step 5: Write `.github/CODEOWNERS`**

```
* @EITANPOD
```

- [ ] **Step 6: Write `.github/dependabot.yml`**

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: terraform
    directory: /infra/bootstrap
    schedule:
      interval: weekly
  - package-ecosystem: terraform
    directory: /infra/aws
    schedule:
      interval: weekly
```

- [ ] **Step 7: Write `.github/pull_request_template.md`**

```markdown
## What

## Why

## Checks
- [ ] CI green
- [ ] No secrets added (gitleaks passes)
- [ ] Infra change? `terraform plan` comment reviewed
```

- [ ] **Step 8: Write `.github/workflows/pre-commit.yml`**

```yaml
name: pre-commit

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.9"
          terraform_wrapper: false
      - uses: terraform-linters/setup-tflint@v6
        with:
          tflint_version: v0.64.0
      - run: tflint --init --config "$(pwd)/.tflint.hcl"
      - uses: actions/setup-python@v7
        with:
          python-version: "3.12"
      - run: pipx install pre-commit
      - run: pre-commit run --all-files --show-diff-on-failure
```

- [ ] **Step 9: Write `README.md`**

```markdown
# Ned

Proactive personal chief-of-staff agent. Watches your mail, calendar and Slack, decides when to interrupt you, reaches you on Telegram. Learns from what you act on.

Design: [docs/superpowers/specs/2026-09-18-ned-design.md](docs/superpowers/specs/2026-09-18-ned-design.md)

## Status

Phase 0: infra bootstrap + AWS (Terraform via GitHub Actions). See [Infra](#infra).

## Infra

All Terraform runs in GitHub Actions. Nothing is applied from a laptop.

| Root module        | State key                     | Trigger                                   |
|--------------------|-------------------------------|-------------------------------------------|
| `infra/bootstrap`  | `bootstrap/terraform.tfstate` | `infra-bootstrap.yml`, manual, one time   |
| `infra/aws`        | `aws/terraform.tfstate`       | PR → plan comment; manual dispatch → apply (gated by env `prod`) |

Local checks only: `pre-commit run --all-files`, `terraform test` (mock provider, no creds).

### First-time bootstrap runbook

Filled in by Task 7.
```

- [ ] **Step 10: Run pre-commit locally**

Run: `cd /Users/eitanpod/eitan/.mywork/ned && pre-commit install && pre-commit run --all-files`
Expected: all hooks `Passed` or `Skipped` (no Terraform files yet, so terraform hooks skip).

- [ ] **Step 11: Commit**

```bash
git add .editorconfig .pre-commit-config.yaml .tflint.hcl .github README.md
git commit -m "chore: repo hygiene (pre-commit, tflint, dependabot, codeowners)"
```

---

### Task 2: `infra/bootstrap` Terraform (state bucket, OIDC provider, CI role)

**Files:**
- Create: `infra/bootstrap/versions.tf`, `variables.tf`, `main.tf`, `ci_role_policy.tf`, `outputs.tf`
- Test: `infra/bootstrap/tests/bootstrap.tftest.hcl`

**Interfaces:**
- Consumes: nothing.
- Produces: output `ci_role_arn` (string) → stored as GitHub variable `AWS_TF_ROLE_ARN`; output `state_bucket` (string) → GitHub variable `TF_STATE_BUCKET`. The CI role trusts `repo:<github_repo>:*` via OIDC.

- [ ] **Step 1: Write the failing test**

`infra/bootstrap/tests/bootstrap.tftest.hcl`:
```hcl
mock_provider "aws" {}

variables {
  github_repo       = "EITANPOD/ned"
  aws_region        = "us-east-1"
  state_bucket_name = "ned-tfstate-test"
}

run "bucket_is_hardened" {
  command = apply

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "state bucket must have versioning enabled"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "state bucket must block public access"
  }
  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.state.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "state bucket must be SSE encrypted"
  }
}

run "ci_role_trusts_only_this_repo" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_role.ci.assume_role_policy, "repo:EITANPOD/ned:*")
    error_message = "CI role trust must be scoped to the repo"
  }
  assert {
    condition     = strcontains(aws_iam_role.ci.assume_role_policy, "sts.amazonaws.com")
    error_message = "CI role trust must require aud=sts.amazonaws.com"
  }
}

run "ci_role_has_no_wildcard_admin" {
  command = apply

  assert {
    condition     = !strcontains(aws_iam_role_policy.ci.policy, "\"Action\":\"*\"") && !strcontains(aws_iam_role_policy.ci.policy, "\"Action\": \"*\"")
    error_message = "CI role policy must not grant Action:*"
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd infra/bootstrap && terraform init -backend=false && terraform test`
Expected: FAIL — `Reference to undeclared resource` (no `.tf` files yet).

- [ ] **Step 3: Write `versions.tf`**

```hcl
terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }

  # Partial config: bucket/region passed via -backend-config in CI.
  # First bootstrap run uses `terraform init -backend=false` (local state),
  # then migrates into this backend.
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ned"
      ManagedBy = "terraform"
      Module    = "bootstrap"
    }
  }
}
```

- [ ] **Step 4: Write `variables.tf`**

```hcl
variable "github_repo" {
  description = "GitHub repo allowed to assume the CI role, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "aws_region" {
  description = "Region for all Ned AWS resources."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}
```

- [ ] **Step 5: Write `main.tf`**

```hcl
data "aws_caller_identity" "current" {}

# --- Terraform remote state -------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- GitHub OIDC -> AWS --------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Policies are plain jsonencode() (not aws_iam_policy_document data sources) so
# `terraform test` with mock_provider can assert on their content.
locals {
  ci_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*" }
      }
    }]
  })
}

resource "aws_iam_role" "ci" {
  name                 = "ned-github-terraform"
  assume_role_policy   = local.ci_trust_policy
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ci" {
  name   = "ned-github-terraform"
  role   = aws_iam_role.ci.id
  policy = local.ci_permissions_policy
}
```

- [ ] **Step 6: Write `ci_role_policy.tf`**

```hcl
locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Least-privilege for what infra/bootstrap + infra/aws manage. Everything scoped to ned-* names.
locals {
  ci_permissions_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
      {
        Sid    = "ReadOwnBootstrap"
        Effect = "Allow"
        Action = [
          "s3:GetBucket*",
          "s3:GetEncryptionConfiguration",
          "s3:GetAccelerateConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration",
          "s3:GetBucketObjectLockConfiguration",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketTagging",
        ]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Sid    = "OidcProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
        ]
        Resource = aws_iam_openid_connect_provider.github.arn
      },
      {
        Sid    = "NedIam"
        Effect = "Allow"
        Action = [
          "iam:CreateUser", "iam:DeleteUser", "iam:GetUser", "iam:TagUser", "iam:UntagUser", "iam:ListGroupsForUser",
          "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:ListAccessKeys", "iam:UpdateAccessKey",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
          "iam:AttachUserPolicy", "iam:DetachUserPolicy", "iam:ListAttachedUserPolicies", "iam:ListUserPolicies",
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
          "iam:PassRole",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:user/ned-*",
          "arn:aws:iam::${local.account_id}:policy/ned-*",
          "arn:aws:iam::${local.account_id}:role/ned-*",
        ]
      },
      {
        Sid      = "Budgets"
        Effect   = "Allow"
        Action   = ["budgets:ViewBudget", "budgets:ModifyBudget"]
        Resource = "arn:aws:budgets::${local.account_id}:budget/ned-*"
      },
      {
        Sid    = "BedrockLoggingConfig"
        Effect = "Allow"
        Action = [
          "bedrock:PutModelInvocationLoggingConfiguration",
          "bedrock:GetModelInvocationLoggingConfiguration",
          "bedrock:DeleteModelInvocationLoggingConfiguration",
        ]
        Resource = "*"
      },
      {
        Sid      = "LogsDescribe"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "NedLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource", "logs:TagLogGroup", "logs:UntagLogGroup", "logs:ListTagsLogGroup",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ned/*"
      },
      {
        Sid    = "NedSns"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
          "sns:ListTagsForResource", "sns:TagResource", "sns:UntagResource",
          "sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:ListSubscriptionsByTopic",
        ]
        Resource = "arn:aws:sns:${var.aws_region}:${local.account_id}:ned-*"
      },
      {
        Sid    = "NedSsmParams"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter",
          "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/ned/*"
      },
      {
        Sid      = "SsmDescribe"
        Effect   = "Allow"
        Action   = "ssm:DescribeParameters"
        Resource = "*"
      },
    ]
  })
}
```

- [ ] **Step 7: Write `outputs.tf`**

```hcl
output "ci_role_arn" {
  description = "Set as GitHub repo variable AWS_TF_ROLE_ARN."
  value       = aws_iam_role.ci.arn
}

output "state_bucket" {
  description = "Set as GitHub repo variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.state.bucket
}
```

- [ ] **Step 8: Run tests + fmt + validate**

Run: `cd infra/bootstrap && terraform fmt -check -recursive && terraform init -backend=false && terraform validate && terraform test`
Expected: `Success! 3 passed, 0 failed.`

- [ ] **Step 9: Run pre-commit (tflint included)**

Run: `cd /Users/eitanpod/eitan/.mywork/ned && tflint --init --config "$(pwd)/.tflint.hcl" && pre-commit run --all-files`
Expected: all Passed.

- [ ] **Step 10: Commit**

```bash
git add infra/bootstrap
git commit -m "feat(infra): bootstrap module - state bucket, GitHub OIDC, CI role"
```

---

### Task 3: `infra-bootstrap.yml` workflow (one-time, manual)

**Files:**
- Create: `.github/workflows/infra-bootstrap.yml`

**Interfaces:**
- Consumes: repo secrets `AWS_BOOTSTRAP_ACCESS_KEY_ID`, `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` (temporary admin keys, deleted after run); repo variables `AWS_REGION`, `TF_STATE_BUCKET`.
- Produces: applied bootstrap stack; state migrated to `s3://$TF_STATE_BUCKET/bootstrap/terraform.tfstate`; job summary prints `ci_role_arn`.

- [ ] **Step 1: Write the workflow**

```yaml
name: infra-bootstrap (one-time)

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type "bootstrap" to confirm. Runs with temporary bootstrap keys.'
        required: true

permissions:
  contents: read

concurrency:
  group: infra-bootstrap
  cancel-in-progress: false

jobs:
  bootstrap:
    if: ${{ inputs.confirm == 'bootstrap' }}
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: infra/bootstrap
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_BOOTSTRAP_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_BOOTSTRAP_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ vars.AWS_REGION }}
      TF_VAR_github_repo: ${{ github.repository }}
      TF_VAR_aws_region: ${{ vars.AWS_REGION }}
      TF_VAR_state_bucket_name: ${{ vars.TF_STATE_BUCKET }}
      TF_IN_AUTOMATION: "true"
    steps:
      - uses: actions/checkout@v7

      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.9"
          terraform_wrapper: false

      - name: Apply with local state
        run: |
          terraform init -backend=false -input=false
          terraform apply -auto-approve -input=false

      - name: Migrate state into the new bucket
        run: |
          terraform init -input=false -force-copy -migrate-state \
            -backend-config="bucket=${TF_VAR_state_bucket_name}" \
            -backend-config="region=${AWS_REGION}"
          terraform plan -input=false -detailed-exitcode

      - name: Publish outputs
        run: |
          {
            echo '## Bootstrap outputs'
            echo
            echo "Set these as repo **variables**:"
            echo
            echo "- AWS_TF_ROLE_ARN = $(terraform output -raw ci_role_arn)"
            echo "- TF_STATE_BUCKET = $(terraform output -raw state_bucket)"
            echo
            echo 'Now delete the bootstrap IAM user + the two AWS_BOOTSTRAP_* secrets.'
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Lint the workflow file**

Run: `cd /Users/eitanpod/eitan/.mywork/ned && pre-commit run check-yaml --all-files`
Expected: Passed.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/infra-bootstrap.yml
git commit -m "ci: one-time infra-bootstrap workflow (local apply, then state migration)"
```

---

### Task 4: `infra/aws` — runtime IAM user, Bedrock invoke policy, SSM secret

**Files:**
- Create: `infra/aws/versions.tf`, `variables.tf`, `iam.tf`, `outputs.tf`
- Test: `infra/aws/tests/iam.tftest.hcl`

**Interfaces:**
- Consumes: nothing from other modules (the state bucket name arrives via `-backend-config`).
- Produces: IAM user `ned-runtime`; SSM SecureString `/ned/runtime/aws_secret_access_key` and String `/ned/runtime/aws_access_key_id` (read by the Phase 8 deploy job); variable `allowed_model_ids` (list(string)) reused by later phases' docs.

- [ ] **Step 1: Write the failing test**

`infra/aws/tests/iam.tftest.hcl`:
```hcl
mock_provider "aws" {}

variables {
  aws_region   = "us-east-1"
  budget_email = "test@example.com"
}

run "runtime_policy_scoped_to_bedrock_invoke" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_policy.runtime_bedrock.policy, "bedrock:InvokeModel")
    error_message = "runtime policy must allow bedrock:InvokeModel"
  }
  assert {
    condition     = strcontains(aws_iam_policy.runtime_bedrock.policy, "amazon.nova-micro-v1:0")
    error_message = "default allowed models must include nova-micro"
  }
  assert {
    condition     = !strcontains(aws_iam_policy.runtime_bedrock.policy, "\"Resource\":\"*\"") || strcontains(aws_iam_policy.runtime_bedrock.policy, "bedrock:ListFoundationModels")
    error_message = "Resource:* only allowed for the ListFoundationModels statement"
  }
}

run "runtime_user_named_and_secret_in_ssm" {
  command = apply

  assert {
    condition     = aws_iam_user.runtime.name == "ned-runtime"
    error_message = "runtime user must be ned-runtime"
  }
  assert {
    condition     = aws_ssm_parameter.runtime_secret.type == "SecureString" && aws_ssm_parameter.runtime_secret.name == "/ned/runtime/aws_secret_access_key"
    error_message = "secret key must be a SecureString at /ned/runtime/aws_secret_access_key"
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd infra/aws && terraform init -backend=false && terraform test`
Expected: FAIL — undeclared resources.

- [ ] **Step 3: Write `versions.tf`**

```hcl
terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }

  backend "s3" {
    key          = "aws/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ned"
      ManagedBy = "terraform"
      Module    = "aws"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
```

- [ ] **Step 4: Write `variables.tf`**

```hcl
variable "aws_region" {
  description = "Region for all Ned AWS resources."
  type        = string
  default     = "us-east-1"
}

variable "allowed_model_ids" {
  description = "Bedrock foundation model IDs the runtime may invoke. Cheapest Nova first; extend freely."
  type        = list(string)
  default = [
    "amazon.nova-micro-v1:0",
    "amazon.nova-lite-v1:0",
    "amazon.nova-2-lite-v1:0",
    "amazon.titan-embed-text-v2:0",
    "amazon.nova-2-multimodal-embeddings-v1:0",
  ]
}

variable "allowed_inference_profile_ids" {
  description = "Cross-region inference profile IDs the runtime may invoke (needed for models like nova-2-lite)."
  type        = list(string)
  default     = ["us.amazon.nova-2-lite-v1:0"]
}

variable "budget_email" {
  description = "Email that receives budget alerts."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD. Alerts fire at 50% actual, 100% actual, 100% forecasted."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "Retention for Bedrock invocation logs."
  type        = number
  default     = 14
}
```

- [ ] **Step 5: Write `iam.tf`**

```hcl
resource "aws_iam_user" "runtime" {
  name = "ned-runtime"
}

# jsonencode (not aws_iam_policy_document) so mock_provider tests can assert on content.
locals {
  runtime_bedrock_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeAllowedModels"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
        ]
        Resource = concat(
          [for m in var.allowed_model_ids : "arn:aws:bedrock:*::foundation-model/${m}"],
          [for p in var.allowed_inference_profile_ids : "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${p}"],
        )
      },
      {
        Sid      = "DiscoverModels"
        Effect   = "Allow"
        Action   = ["bedrock:ListFoundationModels", "bedrock:ListInferenceProfiles"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_policy" "runtime_bedrock" {
  name   = "ned-runtime-bedrock"
  policy = local.runtime_bedrock_policy
}

resource "aws_iam_user_policy_attachment" "runtime_bedrock" {
  user       = aws_iam_user.runtime.name
  policy_arn = aws_iam_policy.runtime_bedrock.arn
}

resource "aws_iam_access_key" "runtime" {
  user = aws_iam_user.runtime.name
}

# Read by the deploy job (Phase 8) via the CI role; never printed.
resource "aws_ssm_parameter" "runtime_key_id" {
  name  = "/ned/runtime/aws_access_key_id"
  type  = "String"
  value = aws_iam_access_key.runtime.id
}

resource "aws_ssm_parameter" "runtime_secret" {
  name  = "/ned/runtime/aws_secret_access_key"
  type  = "SecureString"
  value = aws_iam_access_key.runtime.secret
}
```

- [ ] **Step 6: Write `outputs.tf`**

```hcl
output "runtime_user_name" {
  value = aws_iam_user.runtime.name
}

output "ssm_key_id_param" {
  value = aws_ssm_parameter.runtime_key_id.name
}

output "ssm_secret_param" {
  value = aws_ssm_parameter.runtime_secret.name
}
```

- [ ] **Step 7: Run tests + fmt + validate**

Run: `cd infra/aws && terraform fmt -check && terraform init -backend=false && terraform validate && terraform test tests/iam.tftest.hcl`
Expected: `Success! 2 passed, 0 failed.`

- [ ] **Step 8: Commit**

```bash
git add infra/aws
git commit -m "feat(infra): aws runtime user with least-priv Bedrock invoke, key in SSM"
```

---

### Task 5: `infra/aws` — Bedrock invocation logging + budgets + SNS

**Files:**
- Create: `infra/aws/logging.tf`, `infra/aws/budgets.tf`
- Modify: `infra/aws/outputs.tf`
- Test: `infra/aws/tests/logging.tftest.hcl`, `infra/aws/tests/budgets.tftest.hcl`

**Interfaces:**
- Consumes: `var.log_retention_days`, `var.budget_limit_usd`, `var.budget_email`, `local.account_id` from Task 4.
- Produces: log group `/ned/bedrock`; SNS topic `ned-budget-alerts` (later: SNS→Telegram webhook subscription); budget `ned-monthly`.

- [ ] **Step 1: Write the failing tests**

`infra/aws/tests/logging.tftest.hcl`:
```hcl
mock_provider "aws" {}

variables {
  aws_region   = "us-east-1"
  budget_email = "test@example.com"
}

run "log_group_retention_and_text_only" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_group.bedrock.name == "/ned/bedrock" && aws_cloudwatch_log_group.bedrock.retention_in_days == 14
    error_message = "log group must be /ned/bedrock with 14d retention"
  }
  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].text_data_delivery_enabled == true
    error_message = "text delivery must be on"
  }
  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].embedding_data_delivery_enabled == false && aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].image_data_delivery_enabled == false && aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].video_data_delivery_enabled == false
    error_message = "only text data should be logged"
  }
}

run "bedrock_logging_role_trust_is_conditioned" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_role.bedrock_logging.assume_role_policy, "bedrock.amazonaws.com") && strcontains(aws_iam_role.bedrock_logging.assume_role_policy, "aws:SourceAccount")
    error_message = "logging role must trust bedrock.amazonaws.com with SourceAccount condition"
  }
}
```

`infra/aws/tests/budgets.tftest.hcl`:
```hcl
mock_provider "aws" {}

variables {
  aws_region   = "us-east-1"
  budget_email = "test@example.com"
}

run "budget_limits_and_three_notifications" {
  command = apply

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "10" && aws_budgets_budget.monthly.limit_unit == "USD" && aws_budgets_budget.monthly.time_unit == "MONTHLY"
    error_message = "budget must be 10 USD monthly"
  }
  assert {
    condition     = length(aws_budgets_budget.monthly.notification) == 3
    error_message = "budget must have exactly 3 notifications (50% actual, 100% actual, 100% forecasted)"
  }
  assert {
    condition     = contains([for n in aws_budgets_budget.monthly.notification : n.threshold], 50) && contains([for n in aws_budgets_budget.monthly.notification : n.notification_type], "FORECASTED")
    error_message = "must include a 50% threshold and a FORECASTED notification"
  }
}

run "sns_topic_named" {
  command = apply

  assert {
    condition     = aws_sns_topic.budget_alerts.name == "ned-budget-alerts"
    error_message = "SNS topic must be ned-budget-alerts"
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd infra/aws && terraform test tests/logging.tftest.hcl tests/budgets.tftest.hcl`
Expected: FAIL — undeclared resources.

- [ ] **Step 3: Write `logging.tf`**

```hcl
resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/ned/bedrock"
  retention_in_days = var.log_retention_days
}

locals {
  bedrock_logging_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "bedrock.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${local.account_id}:*" }
      }
    }]
  })

  bedrock_logging_write = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.bedrock.arn}:log-stream:aws/bedrock/modelinvocations"
    }]
  })
}

resource "aws_iam_role" "bedrock_logging" {
  name               = "ned-bedrock-logging"
  assume_role_policy = local.bedrock_logging_trust
}

resource "aws_iam_role_policy" "bedrock_logging_write" {
  name   = "ned-bedrock-logging-write"
  role   = aws_iam_role.bedrock_logging.id
  policy = local.bedrock_logging_write
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  depends_on = [aws_iam_role_policy.bedrock_logging_write]

  logging_config {
    text_data_delivery_enabled      = true
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
  }
}
```

- [ ] **Step 4: Write `budgets.tf`**

```hcl
resource "aws_sns_topic" "budget_alerts" {
  name = "ned-budget-alerts"
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn = aws_sns_topic.budget_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sns:Publish"
      Principal = { Service = "budgets.amazonaws.com" }
      Resource  = aws_sns_topic.budget_alerts.arn
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_budgets_budget" "monthly" {
  name         = "ned-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 50% actual (= $5 at default limit)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # 100% actual
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # 100% forecasted
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.budget_alerts]
}
```

- [ ] **Step 5: Append to `outputs.tf`**

```hcl
output "bedrock_log_group" {
  value = aws_cloudwatch_log_group.bedrock.name
}

output "budget_alerts_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}
```

- [ ] **Step 6: Run all module tests + lint**

Run: `cd infra/aws && terraform fmt -check && terraform validate && terraform test && cd ../.. && pre-commit run --all-files`
Expected: `Success! 5 passed, 0 failed.` and pre-commit all Passed.

- [ ] **Step 7: Commit**

```bash
git add infra/aws
git commit -m "feat(infra): bedrock invocation logging, monthly budget with SNS + email alerts"
```

---

### Task 6: `infra-aws.yml` workflow (PR plan + comment; manual gated apply)

**Files:**
- Create: `.github/workflows/infra-aws.yml`

**Interfaces:**
- Consumes: repo variables `AWS_REGION`, `AWS_TF_ROLE_ARN`, `TF_STATE_BUCKET`, `BUDGET_EMAIL`; GitHub environment `prod` (required reviewer) created in Task 7.
- Produces: PR comment with plan; `tfplan` artifact; apply only in job `apply` bound to `environment: prod`.

- [ ] **Step 1: Write the workflow**

```yaml
name: infra-aws

on:
  pull_request:
    paths:
      - "infra/aws/**"
      - ".github/workflows/infra-aws.yml"
  workflow_dispatch:
    inputs:
      action:
        description: "plan or apply"
        type: choice
        options: [plan, apply]
        default: plan

permissions:
  contents: read
  id-token: write
  pull-requests: write

concurrency:
  group: infra-aws
  cancel-in-progress: false

env:
  TF_IN_AUTOMATION: "true"
  TF_INPUT: "0"
  AWS_REGION: ${{ vars.AWS_REGION }}
  TF_VAR_aws_region: ${{ vars.AWS_REGION }}
  TF_VAR_budget_email: ${{ vars.BUDGET_EMAIL }}

jobs:
  check:
    name: check
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: infra/aws
    steps:
      - uses: actions/checkout@v7
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.9"
          terraform_wrapper: false
      - run: terraform fmt -check -recursive
      - run: terraform init -backend=false
      - run: terraform validate
      - run: terraform test
      - uses: terraform-linters/setup-tflint@v6
        with:
          tflint_version: v0.64.0
      - run: tflint --init --config "$GITHUB_WORKSPACE/.tflint.hcl"
      - run: tflint --config "$GITHUB_WORKSPACE/.tflint.hcl"
      - uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: config
          scan-ref: infra
          exit-code: "1"
          severity: HIGH,CRITICAL

  plan:
    needs: check
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: infra/aws
    outputs:
      exitcode: ${{ steps.plan.outputs.exitcode }}
    steps:
      - uses: actions/checkout@v7
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_TF_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.9"
          terraform_wrapper: false
      - run: |
          terraform init \
            -backend-config="bucket=${{ vars.TF_STATE_BUCKET }}" \
            -backend-config="region=${{ vars.AWS_REGION }}"
      - id: plan
        run: |
          set +e
          terraform plan -out=tfplan -detailed-exitcode -no-color | tee plan.txt
          code=${PIPESTATUS[0]}
          set -e
          echo "exitcode=$code" >> "$GITHUB_OUTPUT"
          [ "$code" -ne 1 ]
      - uses: actions/upload-artifact@v7
        with:
          name: tfplan
          path: |
            infra/aws/tfplan
            infra/aws/plan.txt
          retention-days: 1
      - name: Comment plan on PR
        if: github.event_name == 'pull_request'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          {
            echo "### terraform plan (infra/aws) — exit code ${{ steps.plan.outputs.exitcode }}"
            echo
            echo '```'
            tail -c 60000 plan.txt
            echo '```'
          } > comment.md
          gh pr comment ${{ github.event.pull_request.number }} --body-file comment.md

  apply:
    if: github.event_name == 'workflow_dispatch' && inputs.action == 'apply' && needs.plan.outputs.exitcode == '2'
    needs: plan
    runs-on: ubuntu-latest
    environment: prod
    defaults:
      run:
        working-directory: infra/aws
    steps:
      - uses: actions/checkout@v7
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_TF_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.9"
          terraform_wrapper: false
      - uses: actions/download-artifact@v8
        with:
          name: tfplan
          path: infra/aws
      - run: |
          terraform init \
            -backend-config="bucket=${{ vars.TF_STATE_BUCKET }}" \
            -backend-config="region=${{ vars.AWS_REGION }}"
      - run: terraform apply -input=false tfplan
      - run: terraform output >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Lint**

Run: `cd /Users/eitanpod/eitan/.mywork/ned && pre-commit run check-yaml --all-files`
Expected: Passed.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/infra-aws.yml
git commit -m "ci: infra-aws pipeline - PR plan comment, manual apply gated by prod environment"
```

---

### Task 7: GitHub repo, protections, bootstrap run, first gated apply, README runbook

**Files:**
- Modify: `README.md` (fill "First-time bootstrap runbook")

**Interfaces:**
- Consumes: everything above.
- Produces: live AWS resources; repo variables `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_TF_ROLE_ARN`, `BUDGET_EMAIL`; environment `prod` with required reviewer; branch protection on `main`.

- [ ] **Step 1: Fill the README runbook**

Replace `Filled in by Task 7.` with:

```markdown
1. Create the repo and push `main` (public).
2. In AWS (console, one time): create IAM user `ned-bootstrap` with `AdministratorAccess` and an access key. This user lives for one workflow run.
3. Repo **secrets**: `AWS_BOOTSTRAP_ACCESS_KEY_ID`, `AWS_BOOTSTRAP_SECRET_ACCESS_KEY`.
   Repo **variables**: `AWS_ACCOUNT_ID`, `AWS_REGION=us-east-1`, `TF_STATE_BUCKET=ned-tfstate-<account-id>`, `BUDGET_EMAIL=<you>`.
4. Actions → `infra-bootstrap (one-time)` → Run with input `bootstrap`. Read the job summary.
5. Set repo variable `AWS_TF_ROLE_ARN` from the summary. Delete the `ned-bootstrap` IAM user and both `AWS_BOOTSTRAP_*` secrets.
6. Create environment `prod` with yourself as required reviewer. Enable branch protection on `main` (require PR + `pre-commit` and `infra-aws / check` status checks).
7. Open a PR touching `infra/aws/` → plan appears as a PR comment. Merge.
8. Actions → `infra-aws` → Run workflow with `action=apply` → approve the `prod` deployment → resources created.

Runtime credentials for Ned are in SSM: `/ned/runtime/aws_access_key_id`, `/ned/runtime/aws_secret_access_key` (SecureString). The deploy job reads them; humans do not need to.
```

- [ ] **Step 2: Commit README**

```bash
git add README.md
git commit -m "docs: infra bootstrap runbook"
```

- [ ] **Step 3: Create GitHub repo and push**

Run:
```bash
cd /Users/eitanpod/eitan/.mywork/ned
gh repo create EITANPOD/ned --public --source=. --remote=origin --description "Proactive personal chief-of-staff agent" --push
```
Expected: repo URL printed; `pre-commit` workflow runs green on `main` (check with `gh run list --limit 3`).

- [ ] **Step 4: Set repo variables (account id from profile `eitan`)**

Run:
```bash
ACCOUNT_ID=$(AWS_PROFILE=eitan aws sts get-caller-identity --query Account --output text)
gh variable set AWS_ACCOUNT_ID --body "$ACCOUNT_ID"
gh variable set AWS_REGION --body "us-east-1"
gh variable set TF_STATE_BUCKET --body "ned-tfstate-$ACCOUNT_ID"
gh variable set BUDGET_EMAIL --body "eitanp2001@gmail.com"
gh variable list
```
Expected: four variables listed.

- [ ] **Step 5: USER ACTION — bootstrap IAM user + secrets**

Eitan creates IAM user `ned-bootstrap` (AdministratorAccess, access key) in the AWS console and sets the two repo secrets:
```bash
gh secret set AWS_BOOTSTRAP_ACCESS_KEY_ID
gh secret set AWS_BOOTSTRAP_SECRET_ACCESS_KEY
```
(Interactive prompts; the agent never handles these values.)

- [ ] **Step 6: Run bootstrap workflow and capture role ARN**

Run:
```bash
gh workflow run "infra-bootstrap (one-time)" -f confirm=bootstrap
sleep 20 && gh run watch "$(gh run list --workflow=infra-bootstrap.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
gh run view "$(gh run list --workflow=infra-bootstrap.yml --limit 1 --json databaseId -q '.[0].databaseId')" --log | grep -E 'AWS_TF_ROLE_ARN|TF_STATE_BUCKET'
```
Expected: run succeeds; summary shows `AWS_TF_ROLE_ARN = arn:aws:iam::<acct>:role/ned-github-terraform`.

Then:
```bash
gh variable set AWS_TF_ROLE_ARN --body "arn:aws:iam::<acct>:role/ned-github-terraform"
```

- [ ] **Step 7: USER ACTION — delete bootstrap user and secrets**

```bash
gh secret delete AWS_BOOTSTRAP_ACCESS_KEY_ID
gh secret delete AWS_BOOTSTRAP_SECRET_ACCESS_KEY
```
Eitan deletes IAM user `ned-bootstrap` in the console.

- [ ] **Step 8: Environment `prod` with required reviewer + branch protection**

Run:
```bash
USER_ID=$(gh api user -q .id)
gh api -X PUT repos/EITANPOD/ned/environments/prod \
  --input - <<EOF
{"reviewers":[{"type":"User","id":$USER_ID}],"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}
EOF
gh api -X PUT repos/EITANPOD/ned/branches/main/protection \
  --input - <<'EOF'
{"required_status_checks":{"strict":true,"contexts":["lint","check"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}
EOF
```
Expected: both calls return 200/201 JSON. (`required_pull_request_reviews` is null because a solo maintainer cannot approve their own PR; CI checks are the gate.)

- [ ] **Step 9: First PR to exercise plan comment**

Run:
```bash
git checkout -b ci/first-plan
printf '\n# trigger first plan\n' >> infra/aws/versions.tf
git commit -am "ci: trigger first infra-aws plan"
git push -u origin ci/first-plan
gh pr create --fill
sleep 30 && gh pr checks --watch
gh pr view --comments | head -60
```
Expected: `pre-commit` and `infra-aws` checks green; a comment starting `### terraform plan (infra/aws) — exit code 2` listing resources to add (IAM user, policy, access key, 2 SSM params, log group, logging role, logging config, SNS topic, topic policy, budget).

Then:
```bash
gh pr merge --squash --delete-branch
git checkout main && git pull
```

- [ ] **Step 10: Gated apply**

Run:
```bash
gh workflow run infra-aws -f action=apply
sleep 20 && gh run list --workflow=infra-aws.yml --limit 1
```
Expected: run pauses on job `apply` with status `waiting` (environment `prod`). Eitan approves in the Actions UI. Then:
```bash
gh run watch "$(gh run list --workflow=infra-aws.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```
Expected: success; step summary shows outputs.

- [ ] **Step 11: Verify live resources (read-only, laptop)**

Run:
```bash
AWS_PROFILE=eitan aws budgets describe-budgets --account-id "$(gh variable get AWS_ACCOUNT_ID)" --query 'Budgets[?BudgetName==`ned-monthly`].BudgetLimit' --output text
AWS_PROFILE=eitan aws bedrock get-model-invocation-logging-configuration --region us-east-1 --query 'loggingConfig.cloudWatchConfig.logGroupName' --output text
AWS_PROFILE=eitan aws logs describe-log-groups --log-group-name-prefix /ned/bedrock --query 'logGroups[0].retentionInDays' --output text
AWS_PROFILE=eitan aws ssm describe-parameters --parameter-filters Key=Name,Option=BeginsWith,Values=/ned/runtime --query 'Parameters[].Name' --output text
```
Expected:
```
10 USD
/ned/bedrock
14
/ned/runtime/aws_access_key_id /ned/runtime/aws_secret_access_key
```

- [ ] **Step 12: Verify least-privilege denies a disallowed model (read-only invoke with runtime creds, laptop)**

Run:
```bash
export AWS_ACCESS_KEY_ID=$(AWS_PROFILE=eitan aws ssm get-parameter --name /ned/runtime/aws_access_key_id --query Parameter.Value --output text)
export AWS_SECRET_ACCESS_KEY=$(AWS_PROFILE=eitan aws ssm get-parameter --name /ned/runtime/aws_secret_access_key --with-decryption --query Parameter.Value --output text)
aws bedrock-runtime converse --region us-east-1 --model-id amazon.nova-micro-v1:0 --messages '[{"role":"user","content":[{"text":"Say hi in 3 words."}]}]' --query 'output.message.content[0].text' --output text
aws bedrock-runtime converse --region us-east-1 --model-id amazon.nova-pro-v1:0 --messages '[{"role":"user","content":[{"text":"hi"}]}]' 2>&1 | tail -1
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```
Expected: first call prints a short greeting; second fails with `AccessDeniedException`.

- [ ] **Step 13: Update README status + commit**

Change `## Status` line to `Phase 0 done: infra bootstrap + AWS live. Next: Phase 1 skeleton.` Then:
```bash
git checkout -b docs/phase0-done
git commit -am "docs: phase 0 complete"
git push -u origin docs/phase0-done && gh pr create --fill && gh pr checks --watch && gh pr merge --squash --delete-branch
git checkout main && git pull
```

---

### Task 8: Automated PR reviewers (Claude Code Action via OAuth token + CodeRabbit)

Execution order: run this task BEFORE Task 7 so the first PR already gets reviewed.

**Files:**
- Create: `.github/workflows/claude-review.yml`, `.coderabbit.yaml`, `CLAUDE.md`
- Modify: `README.md` (add "PR review bots" subsection under Infra)

**Interfaces:**
- Consumes: repo secret `CLAUDE_CODE_OAUTH_TOKEN` (set by Eitan in Task 7 via `claude setup-token`), Claude GitHub App + CodeRabbit App installed on the repo (Task 7).
- Produces: on every non-draft PR (not Dependabot), one sticky Claude review comment + inline comments; CodeRabbit summary + inline comments.

- [ ] **Step 1: Write `CLAUDE.md`** (read by Claude Code Action for project context)

```markdown
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
```

- [ ] **Step 2: Write `.github/workflows/claude-review.yml`**

```yaml
name: claude-review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review]

permissions:
  contents: read
  pull-requests: write
  issues: read
  id-token: write

concurrency:
  group: claude-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    if: github.event.pull_request.draft == false && github.actor != 'dependabot[bot]'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          use_sticky_comment: true
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}

            Review this pull request against the rules in CLAUDE.md. Report only
            concrete problems: security issues, correctness bugs, drift from the
            design spec, over-engineering, weak tests. Skip style nits.

            Post ONE overall comment with `gh pr comment` (verdict + at most five
            bullets). Use the inline comment tool (confirmed: true) only for
            defects you can point to by file and line. If nothing is wrong, say
            so in one line.
          claude_args: '--allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*)" --model claude-haiku-4-5-20251001'
```

- [ ] **Step 3: Write `.coderabbit.yaml`**

```yaml
language: en-US

reviews:
  profile: chill
  auto_review:
    enabled: true
    drafts: false
  high_level_summary: true
  poem: false
  path_filters:
    - "!docs/**"
    - "!.superpowers/**"
  path_instructions:
    - path: "infra/**"
      instructions: "Terraform: check least-privilege IAM (resource-scoped, no Action:*), ned- naming, no secrets in code, tests assert real behavior."
    - path: ".github/workflows/**"
      instructions: "GitHub Actions: actions pinned to major tags, minimal per-job permissions, no apply on push, no long-lived cloud keys."
```

- [ ] **Step 4: Add README subsection** (under `## Infra`, after the table)

```markdown
### PR review bots

Every non-draft PR gets two automated reviews:
- **Claude Code Action** (`claude-review.yml`) — reads `CLAUDE.md`, posts one sticky verdict comment + inline defects. Auth: `CLAUDE_CODE_OAUTH_TOKEN` secret from `claude setup-token` (Pro/Max subscription).
- **CodeRabbit** — free on public repos, config in `.coderabbit.yaml`.
Dependabot PRs are skipped by Claude (no secrets on those runs).
```

- [ ] **Step 5: Lint**

Run: `pre-commit run --all-files`
Expected: all Passed/Skipped.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md .github/workflows/claude-review.yml .coderabbit.yaml README.md
git commit -m "ci: automated PR review via Claude Code Action and CodeRabbit"
```

- [ ] **Step 7: USER ACTIONS (after the repo exists, in Task 7)**

1. Install the Claude GitHub App on `EITANPOD/ned`: https://github.com/apps/claude
2. Locally: `claude setup-token` → copy token → `gh secret set CLAUDE_CODE_OAUTH_TOKEN` (interactive; the agent never sees the value).
3. Install CodeRabbit on the repo: https://github.com/marketplace/coderabbitai (sign in with GitHub, select the public repo).
Verification: the first PR in Task 7 Step 9 shows a CodeRabbit summary and a Claude sticky comment within a few minutes.

---

## Self-review notes

- Spec coverage: bootstrap (bucket, lock via `use_lockfile`, OIDC role) ✔ Task 2–3; IAM user least-priv ✔ Task 4; invocation logging 14d ✔ Task 5; budgets $5/$10 + SNS ✔ Task 5; PR plan comment + manual gated apply + fmt/validate/tflint/trivy ✔ Task 6; OIDC auth, no long-lived CI keys ✔; Dependabot, pre-commit, gitleaks, CODEOWNERS, branch protection ✔ Task 1 & 7. Optional Bedrock guardrail deliberately skipped (spec: optional). DynamoDB lock table replaced by S3 native lockfile (Terraform ≥1.10) — simpler, same guarantee.
- Terraform ≥1.14 `use_lockfile` confirmed GA; `mock_provider` requires ≥1.7 ✔. Tests use `command = apply` (not `plan`) because computed ARNs are unknown at plan time; with a mock provider, apply fabricates values and never calls AWS.
- All IAM/SNS policies are `jsonencode()` locals, not `aws_iam_policy_document` data sources, because `mock_provider` returns synthetic data-source values and content assertions would fail.
- Names consistent: `aws_iam_role.ci`, `aws_iam_role_policy.ci`, `aws_iam_user.runtime`, `aws_iam_policy.runtime_bedrock`, `aws_ssm_parameter.runtime_secret`, `aws_cloudwatch_log_group.bedrock`, `aws_bedrock_model_invocation_logging_configuration.this`, `aws_budgets_budget.monthly`, `aws_sns_topic.budget_alerts` used identically in tests and code.
- Branch-protection contexts are the job names `lint` (pre-commit.yml) and `check` (infra-aws.yml); if GitHub reports them differently, copy the names from `gh pr checks`.
