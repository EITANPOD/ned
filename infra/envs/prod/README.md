# envs/prod

Ned's production AWS root: the Bedrock runtime (IAM user, invoke policy,
access key in SSM, invocation logging) and the monthly budget with its SNS
alert topic. Composes `../../modules/bedrock-runtime` and
`../../modules/budget-alerts`; replaces the flat `infra/aws` root in place.

## How CI runs it

The infra workflow plans on PRs/main and applies the saved plan behind the
`prod` environment approval (see `.github/workflows/`; retargeted from
`infra/aws` to this directory in the same restructure). Init is partial:

```sh
terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION"
```

Inputs come from `TF_VAR_aws_region` and `TF_VAR_budget_email` (required, no
default). Permissions boundaries (`ned-user-boundary`, `ned-role-boundary`)
are created by `infra/envs/bootstrap`; their ARNs are built here from the
caller's account ID.

## State key

`backend.tf` keeps key `aws/terraform.tfstate`, the old `infra/aws` key. Do
not change it: the CI roles' S3 grants and plan-stash keys are scoped to it,
and the `moved` blocks rely on reading the existing state.

## Migration (`moved.tf`)

Every `infra/aws` resource moves in place; expected plan is 0 to add, 0 to
destroy. Expected in-place diff: the SNS topic policy gains the sns module's
default account-owner statement.

| Old (`infra/aws`) | New (`infra/envs/prod`) |
|---|---|
| `aws_iam_user.runtime` | `module.bedrock_runtime.module.user.aws_iam_user.this[0]` |
| `aws_iam_policy.runtime_bedrock` | `module.bedrock_runtime.aws_iam_policy.invoke` |
| `aws_iam_user_policy_attachment.runtime_bedrock` | `module.bedrock_runtime.module.user.aws_iam_user_policy_attachment.additional["bedrock"]` |
| `aws_iam_access_key.runtime` | `module.bedrock_runtime.module.user.aws_iam_access_key.this[0]` |
| `aws_ssm_parameter.runtime_key_id` | `module.bedrock_runtime.aws_ssm_parameter.key_id` |
| `aws_ssm_parameter.runtime_secret` | `module.bedrock_runtime.aws_ssm_parameter.secret` |
| `aws_cloudwatch_log_group.bedrock` | `module.bedrock_runtime.aws_cloudwatch_log_group.this` |
| `aws_iam_role.bedrock_logging` | `module.bedrock_runtime.aws_iam_role.logging` |
| `aws_iam_role_policy.bedrock_logging_write` | `module.bedrock_runtime.aws_iam_role_policy.logging_write` |
| `aws_bedrock_model_invocation_logging_configuration.this` | `module.bedrock_runtime.aws_bedrock_model_invocation_logging_configuration.this` |
| `aws_sns_topic.budget_alerts` | `module.budget_alerts.module.topic.aws_sns_topic.this[0]` |
| `aws_sns_topic_policy.budget_alerts` | `module.budget_alerts.module.topic.aws_sns_topic_policy.this[0]` |
| `aws_budgets_budget.monthly` | `module.budget_alerts.aws_budgets_budget.monthly` |

Targets were checked against the installed module sources: `iam-user` v6.8.2
(`aws_iam_user.this`, `aws_iam_access_key.this` use `count`;
`aws_iam_user_policy_attachment.additional` is `for_each` over `policies`,
key `bedrock`) and `sns` v7.1.1 (`aws_sns_topic.this`,
`aws_sns_topic_policy.this` use `count`).

Once the migration has been applied, `moved.tf` can be deleted.
