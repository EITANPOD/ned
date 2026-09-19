# bedrock-runtime

Runtime IAM user for Ned's Bedrock calls: an official `iam-user` module, its
scoped invoke policy, the access key in SSM, and Bedrock invocation logging
to CloudWatch. Carried over from `infra/aws/{iam.tf,logging.tf}`.

## Official modules used

- `terraform-aws-modules/iam/aws//modules/iam-user`, `v6.8.2` — the runtime
  user, its access key, and the policy attachment. `create_login_profile =
  false` (no console password), `create_access_key = true`,
  `permissions_boundary = var.user_boundary_arn`, `policies = { bedrock =
  aws_iam_policy.invoke.arn }`.

## Why the logging role is a plain resource, not `iam-role`

The trust policy is one statement: `bedrock.amazonaws.com` assumes the role,
gated by `aws:SourceAccount` / `aws:SourceArn` conditions. That's a single
`jsonencode()` block. The `iam-role` module's `trust_policy_permissions`
shape (map of statements → `data.aws_iam_policy_document` → dynamic blocks)
was not verified against source for this task and would add indirection
without shrinking the diff — same reasoning as the boundaries in
`github-ci-role`.

## Inputs

| Name | Description | Default |
|---|---|---|
| `aws_region` | Region for Bedrock/log ARNs | — |
| `account_id` | AWS account ID (caller identity) | — |
| `user_name` | Runtime IAM user name | `ned-runtime` |
| `allowed_model_ids` | Bedrock foundation model IDs the runtime may invoke | — |
| `allowed_inference_profile_ids` | Cross-region inference profile IDs the runtime may invoke | — |
| `user_boundary_arn` | Permissions boundary for the runtime user | — |
| `role_boundary_arn` | Permissions boundary for the logging role | — |
| `log_retention_days` | Retention for Bedrock invocation logs | `14` |
| `ssm_prefix` | SSM path prefix for the access key | `/ned/runtime` |
| `tags` | Tags applied to created resources | `{}` |

## Outputs

| Name | Description |
|---|---|
| `user_name` | Runtime IAM user name |
| `ssm_key_id_param` | SSM parameter name for the access key ID |
| `ssm_secret_param` | SSM parameter name for the secret access key |
| `log_group_name` | CloudWatch log group receiving Bedrock invocation logs |

## Migration addresses (for `moved` blocks in `infra/envs/prod`)

| Old (`infra/aws`) | New (this module) |
|---|---|
| `aws_iam_user.runtime` | `module.user.aws_iam_user.this[0]` |
| `aws_iam_access_key.runtime` | `module.user.aws_iam_access_key.this[0]` |
| `aws_iam_user_policy_attachment.runtime_bedrock` | `module.user.aws_iam_user_policy_attachment.additional["bedrock"]` |
| `aws_iam_policy.runtime_bedrock` | `aws_iam_policy.invoke` |
| `aws_ssm_parameter.runtime_key_id` | `aws_ssm_parameter.key_id` |
| `aws_ssm_parameter.runtime_secret` | `aws_ssm_parameter.secret` |
| `aws_cloudwatch_log_group.bedrock` | `aws_cloudwatch_log_group.this` |
| `aws_iam_role.bedrock_logging` | `aws_iam_role.logging` |
| `aws_iam_role_policy.bedrock_logging_write` | `aws_iam_role_policy.logging_write` |
| `aws_bedrock_model_invocation_logging_configuration.this` | `aws_bedrock_model_invocation_logging_configuration.this` (now under `module.bedrock_runtime`) |

All addresses confirmed against `terraform-aws-modules/terraform-aws-iam`
`modules/iam-user/main.tf` at tag `v6.8.2` (resource names `this`/`additional`).

## Known test gap

The `iam-user` module doesn't output `permissions_boundary` (confirmed
against `modules/iam-user/outputs.tf` at `v6.8.2`: only `arn`, `name`,
`unique_id`, `login_profile_*`, `access_key_*`, `ssh_key_*`). Module
resources aren't addressable from outside a `module` block in HCL
expressions — only via state addressing (`moved`, `terraform state show`,
`import`) — so `tests/runtime.tftest.hcl` cannot assert that
`var.user_boundary_arn` reached `module.user`'s `aws_iam_user` resource.
That wiring (`permissions_boundary = var.user_boundary_arn` in `main.tf`) is
verified by code review; after a real apply it can be checked with
`terraform state show module.user.aws_iam_user.this[0]`.
