mock_provider "aws" {
  # Real provider validates *_arn attributes are well-formed; the framework's
  # synthetic computed values aren't, so pin the one referenced downstream.
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock-topic"
    }
  }
}

# aws_iam_policy_document is computed locally by the provider (no AWS call),
# but mock_provider replaces it with a placeholder that isn't valid JSON;
# override its output so the downstream aws_sns_topic_policy resource,
# which requires a valid JSON string, can apply.
override_data {
  target = module.topic.data.aws_iam_policy_document.this[0]
  values = {
    json = "{}"
  }
}

variables {
  email      = "test@example.com"
  account_id = "123456789012"
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
    condition = alltrue([
      for want in [["ACTUAL", 50], ["ACTUAL", 100], ["FORECASTED", 100]] :
      length([for n in aws_budgets_budget.monthly.notification : n if n.notification_type == want[0] && n.threshold == want[1] && n.comparison_operator == "GREATER_THAN" && n.threshold_type == "PERCENTAGE"]) == 1
    ])
    error_message = "must have exactly: 50% ACTUAL, 100% ACTUAL, 100% FORECASTED (GREATER_THAN, PERCENTAGE)"
  }
}

run "sns_topic_named" {
  command = apply

  assert {
    condition     = module.topic.topic_name == "ned-budget-alerts"
    error_message = "SNS topic must be ned-budget-alerts"
  }
}

run "rejects_zero_limit" {
  command = plan

  variables {
    limit_usd = 0
  }

  expect_failures = [var.limit_usd]
}

run "rejects_bad_email" {
  command = plan

  variables {
    email = "not-an-email"
  }

  expect_failures = [var.email]
}

run "rejects_bad_account_id" {
  command = plan

  variables {
    account_id = "12345"
  }

  expect_failures = [var.account_id]
}
