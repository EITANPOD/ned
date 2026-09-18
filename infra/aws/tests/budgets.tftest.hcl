mock_provider "aws" {
  # Real provider validates *_arn attributes are well-formed; the framework's
  # synthetic computed values aren't, so pin the ones referenced downstream.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock-policy"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock-topic"
    }
  }
}

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
