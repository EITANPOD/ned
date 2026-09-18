# Terraform module interface reference

Sourced by fetching exact tags from `raw.githubusercontent.com` and the GitHub
trees API on 2026-09-18. All input/output names below are quoted from source,
not memory. Provider constraint in our stack: `aws ~> 6.65`.

---

## 1. `terraform-aws-modules/s3-bucket/aws` v5.16.1

- Source repo: `terraform-aws-modules/terraform-aws-s3-bucket`, tag `v5.16.1`
- `versions.tf`: `required_version = ">= 1.5.7"`, `aws = { version = ">= 6.42" }` — compatible with our `~> 6.65`.

### Minimal usage (confirmed input names only)

```hcl
module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.16.1"

  bucket = "my-bucket-name"

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle_rule = [
    {
      id      = "expire-old-versions"
      enabled = true
      filter = {
        prefix = ""
      }
      expiration = {
        days                         = 90
        expired_object_delete_marker = false
      }
      noncurrent_version_expiration = {
        days = 30
      }
    }
  ]
}
```

### Confirmed shapes (from `variables.tf`)

- `versioning` is `type = map(string)` (NOT an object type) — `{ enabled = true }` works because HCL coerces bool→string for a map(string), and `main.tf`'s `aws_s3_bucket_versioning.this[0]` reads `var.versioning["enabled"]`, `var.versioning["mfa"]`, `var.versioning["mfa_delete"]`, `var.versioning["status"]` all via `try()`.
- `server_side_encryption_configuration` is a typed object: `rule = optional(object({ bucket_key_enabled, blocked_encryption_types, apply_server_side_encryption_by_default = optional(object({ sse_algorithm (required), kms_master_key_id })) }))`. AES256 needs only `sse_algorithm = "AES256"`; leave `kms_master_key_id` unset.
- `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets` are top-level bools, default `true` each. **But** the `aws_s3_bucket_public_access_block` resource is only created when `var.attach_public_policy` is `true` (default `true`) — a differently-named gate than the four block_* vars themselves (module's own TODO comment admits this is a naming wart pending a breaking-change fix).
- `lifecycle_rule` is `list(object({ id, prefix, enabled, status, abort_incomplete_multipart_upload_days, expiration = optional(object({ date, days, expired_object_delete_marker })), filter = optional(object({ object_size_greater_than, object_size_less_than, prefix, tags, tag })), noncurrent_version_expiration = optional(object({ newer_noncurrent_versions, days, noncurrent_days })), noncurrent_version_transition, transition }))`. Both a top-level `prefix`/`enabled` AND a nested `filter.prefix` exist — use `filter.prefix` per the example in the module's own examples (top-level `prefix`/`enabled` are legacy pass-through fields).

### Outputs (from `outputs.tf`)

- `s3_bucket_id` (NOT `bucket_id`) — `try(aws_s3_bucket.this[0].id, aws_s3_directory_bucket.this[0].bucket, null)`
- `s3_bucket_arn` (NOT `bucket_arn`) — `try(aws_s3_bucket.this[0].arn, null)`
- `aws_s3_bucket_versioning_status`, `s3_bucket_lifecycle_configuration_rules`, `s3_bucket_policy`, etc.

### Gotchas

- Internal resource addresses (for `moved`/import blocks): `aws_s3_bucket.this[0]`, `aws_s3_bucket_versioning.this[0]`, `aws_s3_bucket_server_side_encryption_configuration.this[0]`, `aws_s3_bucket_public_access_block.this[0]`, `aws_s3_bucket_lifecycle_configuration.this[0]`, `aws_s3_bucket_policy.this[0]`, `aws_s3_bucket_ownership_controls.this[0]`.
- The module gates bucket creation on `local.create_bucket = var.create_bucket && var.putin_khuylo`. `putin_khuylo` is a real variable (default `true`, description ties module usage to a political statement about Ukraine) — harmless if left at default, but it must not be explicitly set to `false` or bucket creation silently no-ops.
- Output names carry the `s3_bucket_` / `aws_s3_bucket_` prefix (a maintainer TODO says this is intentionally not yet renamed since it's a breaking change) — do not assume bare `id`/`arn` outputs.

---

## 2. `terraform-aws-modules/iam/aws` v6.8.2 — submodules

- Source repo: `terraform-aws-modules/terraform-aws-iam`, tag `v6.8.2`
- This repo has **no root module** (root has only `modules/`, `examples/`, `wrappers/` — confirmed via GitHub trees API). Every submodule below has its own `required_version = ">= 1.5.7"` and `aws = { version = ">= 6.28" }` (iam-oidc-provider also requires `tls = { version = ">= 3.0" }`). All compatible with `~> 6.65`.

### 2a. `modules/iam-oidc-provider`

```hcl
module "github_oidc" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "6.8.2"

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = { Name = "github-oidc" }
}
```

- Inputs (`variables.tf`): `create` (bool, default true), `tags`, `client_id_list` (list(string), default `[]` — module falls back to `coalescelist(var.client_id_list, ["sts.${dns_suffix}"])` i.e. `sts.amazonaws.com` if empty), `url` (string, default `"https://token.actions.githubusercontent.com"`).
- Outputs: `arn` — `try(aws_iam_openid_connect_provider.this[0].arn, null)`; `url`.
- Internal resource address: `aws_iam_openid_connect_provider.this[0]`.
- Uses `data.tls_certificate.this[0]` (requires the `tls` provider fetching thumbprint from `var.url`) — not just the `aws` provider.

### 2b. `modules/iam-role` — CRITICAL: GitHub OIDC trust `sub` condition

> Ned does **not** use `enable_github_oidc` (its `ForAllValues:StringEquals` aud condition passes when the key is absent); see the Phase 0c plan, Task 1, for the explicit `trust_policy_permissions` form. The example below documents the module only.

```hcl
module "github_actions_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.8.2"

  name = "gha-deploy-role"

  enable_github_oidc      = true
  oidc_wildcard_subjects  = ["EITANPOD@164246517/ned@1376066666:*"]

  max_session_duration = 3600
  permissions_boundary  = null

  create_inline_policy = true
  inline_policy_permissions = {
    deny_dangerous = {
      sid       = "DenyDangerous"
      effect    = "Deny"
      actions   = ["iam:*"]
      resources = ["*"]
    }
    allow_read = {
      sid       = "AllowRead"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["*"]
    }
  }

  policies = {}
}
```

**Exact trust-condition construction, quoted from `modules/iam-role/main.tf` (GitHub OIDC statement, lines ~86-147):**

```hcl
condition {
  test     = "ForAllValues:StringEquals"
  variable = "${var.github_provider}:aud"
  values   = coalescelist(var.oidc_audiences, ["sts.amazonaws.com"])
}

dynamic "condition" {
  for_each = length(var.oidc_wildcard_subjects) > 0 ? [1] : []
  content {
    test     = "StringLike"
    variable = "${var.github_provider}:sub"
    # Strip `repo:` to normalize for cases where users may prepend it
    values = [for subject in var.oidc_wildcard_subjects : "repo:${trimprefix(subject, "repo:")}"]
  }
}
```

Answering the task's exact question:
- Audience is fixed at `sts.amazonaws.com` **unless** `oidc_audiences` is set (default `[]` → `coalescelist` falls back to `["sts.amazonaws.com"]`). Test is `ForAllValues:StringEquals` on `<provider>:aud`.
- The `sub` condition test is `StringLike` (not StringEquals) when using `oidc_wildcard_subjects`.
- The module **does** prepend `repo:` — via `trimprefix(subject, "repo:")` then re-prepending, so it's idempotent whether or not you already typed `repo:`.
- Passing `oidc_wildcard_subjects = ["EITANPOD@164246517/ned@1376066666:*"]` produces condition value: **`"repo:EITANPOD@164246517/ned@1376066666:*"`**, tested with `StringLike` against `token.actions.githubusercontent.com:sub` (default `var.github_provider`).
- `var.github_provider` default: `"token.actions.githubusercontent.com"` (no `https://`).
- There is **no** `oidc_fully_qualified_subjects` variable in this module — only `oidc_subjects` (exact match, `StringEquals`) and `oidc_wildcard_subjects` (`StringLike`). The task's assumed name `oidc_fully_qualified_subjects` does not exist; use `oidc_subjects` for exact-match subjects instead.
- There is also **no** `oidc_provider_urls` input consumed by the GitHub-OIDC statement — `oidc_provider_urls` only feeds the separate "Generic OIDC" statement block (`var.enable_oidc`), not `enable_github_oidc`. For GitHub OIDC use `github_provider` (defaults correctly, normally left unset).

**Deny + multiple statements via `inline_policy_permissions`:** confirmed supported. Exact object shape from `variables.tf`:

```hcl
variable "inline_policy_permissions" {
  type = map(object({
    sid           = optional(string)
    actions       = optional(list(string))
    not_actions   = optional(list(string))
    effect        = optional(string, "Allow")   # set "Deny" per-entry
    resources     = optional(list(string))
    not_resources = optional(list(string))
    principals = optional(list(object({
      type        = string
      identifiers = list(string)
    })))
    not_principals = optional(list(object({
      type        = string
      identifiers = list(string)
    })))
    condition = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })))
  }))
  default = null
}
```
Each map key becomes a distinct `statement` block in the generated `aws_iam_policy_document`, so multiple entries (including mixed Allow/Deny) are natively supported; `sid` defaults to the map key via `try(coalesce(statement.value.sid, statement.key))`. Requires `create_inline_policy = true`.

- Other confirmed inputs: `name`, `use_name_prefix` (default true — role name becomes a *prefix* unless set false), `path`, `description`, `max_session_duration`, `permissions_boundary`, `policies` (map of policy ARNs, attached via `aws_iam_role_policy_attachment.this`), `create_inline_policy` (default false), `enable_oidc`, `oidc_provider_urls`, `oidc_subjects`, `oidc_wildcard_subjects`, `oidc_audiences`, `enable_github_oidc`, `github_provider`, `enable_bitbucket_oidc`, `enable_saml`, `create_instance_profile`.
- Outputs: `name`, `arn`, `unique_id`, `instance_profile_arn/id/name/unique_id`.
- Internal resource addresses: `aws_iam_role.this[0]`, `aws_iam_role_policy_attachment.this["<key>"]`, `aws_iam_role_policy.inline[0]`, `aws_iam_instance_profile.this[0]`, and the trust-policy data source `data.aws_iam_policy_document.this[0]`.

### 2c. `modules/iam-user`

```hcl
module "ci_user" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-user"
  version = "6.8.2"

  name                  = "ci-deploy-user"
  permissions_boundary  = null
  create_access_key     = true
  create_login_profile  = false
  policies              = { readonly = "arn:aws:iam::aws:policy/ReadOnlyAccess" }
}
```

- Confirmed inputs: `name`, `path`, `permissions_boundary`, `force_destroy`, `policies` (map name→ARN, attaches via `aws_iam_user_policy_attachment.additional`), `create_login_profile` (default true), `pgp_key`, `password_length`, `password_reset_required`, `create_access_key` (default true), `access_key_status`, `create_ssh_key`, `create_inline_policy`, `inline_policy_permissions` (same shape as iam-role).
- **Secret storage: it does NOT use SSM or any external secret store.** `aws_iam_access_key.this[0]` and `aws_iam_user_login_profile.this[0]` are plain resources whose secret attributes (`secret`, `password`) land in Terraform state (optionally PGP-encrypted in state if `pgp_key` is set — `var.pgp_key` accepts a base64 PGP public key or `keybase:username`). If `pgp_key` is null the secret is stored in state in cleartext.
- Outputs (sensitive-marked): `access_key_id` (not sensitive), `access_key_secret` (`sensitive = true`), `access_key_encrypted_secret`, `access_key_fingerprint`, `access_key_ses_smtp_password_v4` (sensitive), `login_profile_password` (sensitive), `login_profile_encrypted_password`, `login_profile_key_fingerprint`.
- Internal resource addresses: `aws_iam_user.this[0]`, `aws_iam_user_policy_attachment.additional["<key>"]`, `aws_iam_user_policy.inline[0]`, `aws_iam_user_login_profile.this[0]`, `aws_iam_access_key.this[0]`, `aws_iam_user_ssh_key.this[0]`.

### 2d. `modules/iam-policy`

```hcl
module "policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.8.2"

  name   = "my-policy"
  path   = "/"
  policy = data.aws_iam_policy_document.example.json
}
```

- Inputs: `create`, `name`, `name_prefix`, `path`, `description`, `policy` (string — a rendered JSON document, despite the description text calling it "the path of the policy in IAM (tpl file)", which is a stale docstring; `main.tf` passes it straight to `aws_iam_policy.policy.policy`), `tags`.
- Outputs: `id`, `arn`, `name`, `policy`.
- Internal resource address: `aws_iam_policy.policy[0]` (note: resource **name** is `policy`, not `this`).

---

## 3. `terraform-aws-modules/sns/aws` v7.1.1

- Source repo: `terraform-aws-modules/terraform-aws-sns`, tag `v7.1.1`
- `versions.tf`: `required_version = ">= 1.5.7"`, `aws = { version = ">= 6.28" }`.

```hcl
module "sns_topic" {
  source  = "terraform-aws-modules/sns/aws"
  version = "7.1.1"

  name = "my-topic"

  topic_policy_statements = {
    allow_publish = {
      sid     = "AllowPublish"
      actions = ["sns:Publish"]
      principals = [
        {
          type        = "Service"
          identifiers = ["events.amazonaws.com"]
        }
      ]
      # resources defaults to [aws_sns_topic.this[0].arn] if omitted
    }
  }

  subscriptions = {
    email = {
      protocol = "email"
      endpoint = "alerts@example.com"
    }
  }
}
```

- Confirmed inputs: `create`, `region`, `tags`, `name`, `use_name_prefix`, `fifo_topic`, `kms_master_key_id`, `create_topic_policy` (default true), `enable_default_topic_policy` (default true), `topic_policy` (string — externally supplied full JSON, alternative to `topic_policy_statements`), `topic_policy_statements` (map, same statement object shape as iam-role's `inline_policy_permissions`: `sid, actions, not_actions, effect (default "Allow"), resources, not_resources, principals, not_principals, condition`), `create_subscription` (default true), `subscriptions` (map object: `endpoint` (required), `protocol` (required), `confirmation_timeout_in_minutes`, `delivery_policy`, `endpoint_auto_confirms`, `filter_policy`, `filter_policy_scope`, `raw_message_delivery`, `redrive_policy`, `replay_policy`, `subscription_role_arn`).
- Gotcha: in `topic_policy_statements`, `resources` defaults to the topic's own ARN (`[aws_sns_topic.this[0].arn]`) if you omit it — you don't need to reference the topic ARN yourself before it exists.
- Outputs: `topic_arn`, `topic_id`, `topic_name`, `topic_owner`, `topic_beginning_archive_time`, `subscriptions` (map of full `aws_sns_topic_subscription.this` objects).
- Internal resource addresses: `aws_sns_topic.this[0]`, `aws_sns_topic_policy.this[0]`, `aws_sns_topic_subscription.this["<key>"]`, `aws_sns_topic_data_protection_policy.this[0]`.

---

## 4. `terraform-aws-modules/cloudwatch/aws//modules/log-group` v5.7.3

- Source repo: `terraform-aws-modules/terraform-aws-cloudwatch`, tag `v5.7.3`. Repo root has no top-level `main.tf`/`variables.tf` (only `modules/`, confirmed via GitHub trees API) — always reference via the `//modules/log-group` subpath.
- Submodule `versions.tf`: `required_version = ">= 1.0"`, `aws = { version = ">= 5.81" }`.

```hcl
module "log_group" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/log-group"
  version = "5.7.3"

  name              = "/my/service/log-group"
  retention_in_days = 30
  tags              = { Name = "my-service" }
}
```

- Whole module is 12 lines (`main.tf`) — extremely thin wrapper around a single resource. All inputs: `create`, `name`, `name_prefix`, `retention_in_days` (number; has a hard `validation` block restricting to the exact AWS-allowed set: `0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653` — an out-of-list value fails plan, not apply), `kms_key_id`, `log_group_class`, `skip_destroy`, `tags`.
- Outputs: `cloudwatch_log_group_name` (default `""` not `null` when not created), `cloudwatch_log_group_arn` (default `""` not `null`).
- Internal resource address: `aws_cloudwatch_log_group.this[0]`.

---

## Things I could not confirm

- Whether the s3-bucket module's `lifecycle_rule[*].filter.tag` vs `.tags` (both exist as separate optional fields) map 1:1 to a single-tag vs multi-tag AWS filter — did not trace the `dynamic` block in `main.tf` that consumes them (only confirmed the variable type shape).
- Did not verify runtime behavior (`terraform plan`) against a real AWS account for any of the four modules — this is a static source read only, no `terraform init`/`plan` was run.
- Did not check the `wrappers/` directories in the iam and cloudwatch repos (for_each wrapper modules) since the task only asked about the named submodules.
