# github-ci-role

GitHub Actions -> AWS access for Ned's Terraform CI: the GitHub OIDC provider, two CI roles, and the
two permissions boundaries every CI-created principal must carry.

| Role | Trusted OIDC `sub` | Can do |
|------|--------------------|--------|
| `ned-github-terraform` (apply) | `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:prod` | Least-privilege writes on `ned-*` resources (carried over from `infra/bootstrap/ci_role_policy.tf`, every Sid kept) |
| `ned-github-terraform-plan` (plan) | `...:pull_request`, `...:ref:refs/heads/main` | Read-only on `ned-*` resources; reads state `aws/*`; writes only `plans/*` and the state lockfile `aws/*.tflock` |

PR-authored Terraform therefore never runs with write credentials. The numeric owner/repo ids in the
subject mean a renamed or re-created repo cannot re-acquire either role.

## Official modules used

- `terraform-aws-modules/iam/aws//modules/iam-oidc-provider` `6.8.2` — the OIDC provider.
- `terraform-aws-modules/iam/aws//modules/iam-role` `6.8.2` — both roles and their inline policies.

Trust is set with the iam-role input `trust_policy_permissions` (from the module's `variables.tf`:
`type = map(object({ sid, actions, not_actions, effect = optional(string, "Allow"), resources,
not_resources, principals = optional(list(object({ type, identifiers }))), not_principals,
condition = optional(list(object({ test, variable, values }))) }))`), with an explicit
`StringEquals` on `token.actions.githubusercontent.com:aud` and `StringLike` on `...:sub`.
The module's `enable_github_oidc` is deliberately not used: it writes `ForAllValues:StringEquals` on
`aud`, which evaluates true when the key is absent.

Permissions are set with `inline_policy_permissions` (same object shape; the map key becomes the Sid).

## Why the boundaries are plain resources

`ned-user-boundary` and `ned-role-boundary` are single `aws_iam_policy` resources. The official
`iam-policy` wrapper adds nothing over the resource (it passes `name`/`policy` straight through) and
would only lengthen the address.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Apply role name (also its inline policy name) | `string` | `"ned-github-terraform"` | no |
| plan_role_name | Plan role name (also its inline policy name) | `string` | `"ned-github-terraform-plan"` | no |
| github_repo | Repo as `owner/name` | `string` | n/a | yes |
| github_owner_id | Numeric GitHub owner id (`> 0`) | `number` | n/a | yes |
| github_repo_id | Numeric GitHub repo id (`> 0`) | `number` | n/a | yes |
| state_bucket_arn | Terraform state bucket ARN | `string` | n/a | yes |
| aws_region | Region of the managed Ned resources | `string` | n/a | yes |
| account_id | 12-digit AWS account id | `string` | n/a | yes |
| tags | Tags for the OIDC provider and roles | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| role_arn | Apply role ARN (`AWS_TF_ROLE_ARN`) |
| plan_role_arn | Plan role ARN |
| oidc_provider_arn | GitHub OIDC provider ARN |
| user_boundary_arn | Boundary for every CI-created IAM user |
| role_boundary_arn | Boundary for every CI-created IAM role |

## Migration from `infra/bootstrap`

| Old address (`infra/bootstrap`) | New address (inside this module) |
|---------------------------------|----------------------------------|
| `aws_iam_openid_connect_provider.github` | `module.oidc_provider.aws_iam_openid_connect_provider.this[0]` |
| `aws_iam_role.ci` | `module.role.aws_iam_role.this[0]` |
| `aws_iam_role_policy.ci` | `module.role.aws_iam_role_policy.inline[0]` |
| `aws_iam_policy.user_boundary` | `aws_iam_policy.user_boundary` |
| `aws_iam_policy.role_boundary` | `aws_iam_policy.role_boundary` |

- Inline policy name: iam-role 6.8.2 sets `aws_iam_role_policy.inline` `name = var.use_name_prefix ? null : var.name`.
  With `use_name_prefix = false` and `name = "ned-github-terraform"` it keeps the live name
  `ned-github-terraform`, so the move is in place (name is ForceNew; no replace).
- Expected in-place changes after the moves: the apply-role trust `sub` narrows from `...:*` to
  `...:environment:prod` (intended); `force_detach_policies` becomes `true` (the module hard-codes it);
  the OIDC provider gains an explicit `thumbprint_list` from the module's `tls_certificate` lookup; tags.
  The plan role is new (1 to add).

## Tests

`terraform test` (mock providers, no AWS). Child-module resources are not addressable from a test, and
under `mock_provider` the official module's `aws_iam_policy_document` renders synthetic JSON, so the
tests assert on the statement maps the module is fed (`local.ci_statements`, `local.plan_statements`,
`local.trust`) plus the module outputs; the module renders each map entry 1:1 into a statement.
