mock_provider "aws" {
  # Real provider validates *_arn attributes are well-formed; the framework's
  # synthetic computed values aren't, so pin the one referenced downstream.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
}

variables {
  aws_region        = "us-east-1"
  account_id        = "123456789012"
  role_boundary_arn = "arn:aws:iam::123456789012:policy/ned-role-boundary"
  repo              = "EITANPOD/ned"
}

run "approver" {
  command = apply

  assert {
    condition     = aws_lambda_function.this.function_name == "ned-telegram-approver" && aws_lambda_function.this.runtime == "python3.12"
    error_message = "function name/runtime"
  }
  assert {
    condition     = aws_iam_role.this.permissions_boundary == var.role_boundary_arn
    error_message = "execution role must carry ned-role-boundary"
  }
  assert {
    condition     = local.statements[0].Resource == [for n in local.param_names : "arn:aws:ssm:us-east-1:123456789012:parameter${n}"]
    error_message = "SSM read scoped to exactly the four approver parameters"
  }
  assert {
    condition     = aws_lambda_function_url.this.authorization_type == "NONE"
    error_message = "Telegram cannot sign requests; auth is the secret header"
  }
  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/ned/lambda/telegram-approver" && aws_lambda_function.this.logging_config[0].log_group == "/ned/lambda/telegram-approver"
    error_message = "logs go to a /ned/ group (the role boundary only allows /ned/*)"
  }
}
