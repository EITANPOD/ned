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

  # permissions_boundary is ARN-validated, so the account id must look real.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
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
    condition     = aws_sns_topic.budget_alerts.name == "ned-budget-alerts"
    error_message = "SNS topic must be ned-budget-alerts"
  }
}
