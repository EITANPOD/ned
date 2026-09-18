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

run "runtime_policy_scoped_to_bedrock_invoke" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_policy.runtime_bedrock.policy, "bedrock:InvokeModel")
    error_message = "runtime policy must allow bedrock:InvokeModel"
  }
  assert {
    condition     = strcontains(aws_iam_policy.runtime_bedrock.policy, "amazon.nova-micro-v1:0")
    error_message = "default allowed models must include nova-micro"
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.runtime_bedrock.policy).Statement : s if s.Resource == "*"]) == 1 && [for s in jsondecode(aws_iam_policy.runtime_bedrock.policy).Statement : s.Sid if s.Resource == "*"][0] == "DiscoverModels"
    error_message = "exactly one statement may use Resource:* and it must be DiscoverModels"
  }
}

run "runtime_user_named_and_secret_in_ssm" {
  command = apply

  assert {
    condition     = aws_iam_user.runtime.name == "ned-runtime"
    error_message = "runtime user must be ned-runtime"
  }
  assert {
    condition     = aws_ssm_parameter.runtime_secret.type == "SecureString" && aws_ssm_parameter.runtime_secret.name == "/ned/runtime/aws_secret_access_key"
    error_message = "secret key must be a SecureString at /ned/runtime/aws_secret_access_key"
  }
  assert {
    condition     = endswith(aws_iam_user.runtime.permissions_boundary, ":policy/ned-permissions-boundary")
    error_message = "runtime user must carry the ned-permissions-boundary"
  }
}
