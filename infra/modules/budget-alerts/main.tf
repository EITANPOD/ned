module "topic" {
  source  = "terraform-aws-modules/sns/aws"
  version = "7.1.1"

  name            = var.topic_name
  use_name_prefix = false

  # Skip the module's default owner statement (Principal AWS "*" + management
  # actions) — least privilege: only budgets.amazonaws.com may publish.
  enable_default_topic_policy = false

  topic_policy_statements = {
    budgets_publish = {
      sid     = "AllowBudgetsPublish"
      actions = ["sns:Publish"]
      principals = [{
        type        = "Service"
        identifiers = ["budgets.amazonaws.com"]
      }]
      condition = [{
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [var.account_id]
      }]
    }
  }

  # Budgets is a subscriber via aws_budgets_budget, not an SNS subscription.
  create_subscription = false

  tags = var.tags
}

#trivy:ignore:AVD-AWS-0095 Budget alerts carry no sensitive data; budgets.amazonaws.com cannot publish to a topic encrypted with the AWS-managed aws/sns key, and a CMK costs ~$1/month.
resource "aws_budgets_budget" "monthly" {
  # topic_arn is derived from aws_sns_topic.this[0] alone; wait for the whole
  # module (including the topic policy) so budgets can actually publish.
  depends_on = [module.topic]

  name         = var.name
  budget_type  = "COST"
  limit_amount = tostring(var.limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 50% actual
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email]
    subscriber_sns_topic_arns  = [module.topic.topic_arn]
  }

  # 100% actual
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email]
    subscriber_sns_topic_arns  = [module.topic.topic_arn]
  }

  # 100% forecasted
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.email]
    subscriber_sns_topic_arns  = [module.topic.topic_arn]
  }
}
