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
    condition     = !strcontains(aws_iam_policy.runtime_bedrock.policy, "\"Resource\":\"*\"") || strcontains(aws_iam_policy.runtime_bedrock.policy, "bedrock:ListFoundationModels")
    error_message = "Resource:* only allowed for the ListFoundationModels statement"
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
}
