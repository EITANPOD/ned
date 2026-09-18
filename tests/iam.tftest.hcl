mock_provider "aws" {
  # Real provider validates policy_arn is well-formed; the framework's synthetic
  # computed value for aws_iam_policy.arn isn't, so pin it to a valid shape.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock-policy"
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
