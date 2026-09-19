# budget-alerts

SNS alert topic (official `terraform-aws-modules/sns/aws`, v7.1.1) plus a
monthly AWS Budget with three notifications: 50% actual, 100% actual, 100%
forecasted (all `GREATER_THAN` / `PERCENTAGE`). Each notification fans out to
an email address and to the SNS topic; the budget is an SNS *subscriber*
(`subscriber_sns_topic_arns`), not an `aws_sns_topic_subscription`, so the
module sets `create_subscription = false` on the topic.

## Topic policy

`topic_policy_statements` adds a statement allowing `budgets.amazonaws.com`
to `sns:Publish`, scoped with an `aws:SourceAccount` condition to
`var.account_id`. Default owner statement disabled
(`enable_default_topic_policy = false`) — the topic policy contains only
`AllowBudgetsPublish` (matches the live policy; migration shows at most a
Sid/Resource cosmetic in-place update).

## Trivy

`AVD-AWS-0095` (SNS topic should use a CMK) is ignored: AWS Budgets cannot
publish to a topic encrypted with a customer-managed KMS key, only the
AWS-managed `aws/sns` key, and the topic carries no sensitive data. The
`#trivy:ignore:AVD-AWS-0095` comment sits directly above the `module "topic"`
block in `main.tf`. Verified: trivy does parse the downloaded registry module
(`.terraform/modules/topic`), but its misconfig engine does not raise
`AVD-AWS-0095` for module-instantiated resources in the installed version
(confirmed 0 misconfigurations with or without the comment present). The
comment is documentation of intent at the call site, kept in case a future
trivy version starts raising this check for module-instantiated resources.

## Migrating from `infra/aws/budgets.tf`

State addresses change when moving to this module. `moved` blocks for the
env root that adopts this module:

```hcl
moved {
  from = aws_sns_topic.budget_alerts
  to   = module.budget_alerts.module.topic.aws_sns_topic.this[0]
}

moved {
  from = aws_sns_topic_policy.budget_alerts
  to   = module.budget_alerts.module.topic.aws_sns_topic_policy.this[0]
}

moved {
  from = aws_budgets_budget.monthly
  to   = module.budget_alerts.aws_budgets_budget.monthly
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Budget name. | `string` | `"ned-monthly"` | no |
| topic\_name | SNS topic name for budget alerts. | `string` | `"ned-budget-alerts"` | no |
| limit\_usd | Monthly cost budget in USD. | `number` | `10` | no |
| email | Email address that receives budget alerts. | `string` | n/a | yes |
| account\_id | AWS account ID allowed to publish to the alert topic. | `string` | n/a | yes |
| tags | Tags applied to the SNS topic. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| topic\_arn | ARN of the budget alerts SNS topic. |
| budget\_name | Name of the monthly budget. |
