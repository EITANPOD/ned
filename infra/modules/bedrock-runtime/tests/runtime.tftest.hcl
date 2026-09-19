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

  mock_resource "aws_iam_user" {
    defaults = {
      arn = "arn:aws:iam::123456789012:user/mock-user"
    }
  }
}

variables {
  aws_region                    = "us-east-1"
  account_id                    = "123456789012"
  user_boundary_arn             = "arn:aws:iam::123456789012:policy/ned-user-boundary"
  role_boundary_arn             = "arn:aws:iam::123456789012:policy/ned-role-boundary"
  allowed_model_ids             = ["amazon.nova-micro-v1:0"]
  allowed_inference_profile_ids = ["us.amazon.nova-2-lite-v1:0"]
}

run "invoke_policy_scoped_to_bedrock_invoke" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_policy.invoke.policy, "bedrock:InvokeModel")
    error_message = "invoke policy must allow bedrock:InvokeModel"
  }
  assert {
    condition     = strcontains(aws_iam_policy.invoke.policy, "amazon.nova-micro-v1:0")
    error_message = "allowed models must be reflected in the policy"
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.invoke.policy).Statement : s if s.Resource == "*"]) == 1 && [for s in jsondecode(aws_iam_policy.invoke.policy).Statement : s.Sid if s.Resource == "*"][0] == "DiscoverModels"
    error_message = "exactly one statement may use Resource:* and it must be DiscoverModels"
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.invoke.policy).Statement : s if s.Sid != "DiscoverModels" && contains(flatten([s.Resource]), "*")]) == 0
    error_message = "only DiscoverModels may use Resource:*"
  }
}

run "runtime_user_named_and_secret_in_ssm" {
  command = apply

  assert {
    condition     = module.user.name == "ned-runtime"
    error_message = "runtime user must be ned-runtime"
  }
  assert {
    condition     = aws_ssm_parameter.key_id.type == "String" && aws_ssm_parameter.key_id.name == "/ned/runtime/aws_access_key_id"
    error_message = "access key id must be a String at /ned/runtime/aws_access_key_id"
  }
  assert {
    condition     = aws_ssm_parameter.secret.type == "SecureString" && aws_ssm_parameter.secret.name == "/ned/runtime/aws_secret_access_key"
    error_message = "secret key must be a SecureString at /ned/runtime/aws_secret_access_key"
  }
  # NOTE: the official iam-user module does not output `permissions_boundary`
  # (confirmed against modules/iam-user/outputs.tf at v6.8.2), and module
  # resources aren't addressable from outside in HCL expressions (only state
  # addressing, e.g. `moved`/`terraform state show`, reaches them). So the
  # `user_boundary_arn -> module.user.permissions_boundary` wiring in main.tf
  # can't be asserted here; verified by code review instead. See README.
}

run "log_group_retention_and_text_only" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/ned/bedrock" && aws_cloudwatch_log_group.this.retention_in_days == 14
    error_message = "log group must be /ned/bedrock with 14d retention"
  }
  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].text_data_delivery_enabled == true
    error_message = "text delivery must be on"
  }
  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].embedding_data_delivery_enabled == false && aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].image_data_delivery_enabled == false && aws_bedrock_model_invocation_logging_configuration.this.logging_config[0].video_data_delivery_enabled == false
    error_message = "only text data should be logged"
  }
}

run "bedrock_logging_role_trust_is_conditioned" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_role.logging.assume_role_policy, "bedrock.amazonaws.com") && strcontains(aws_iam_role.logging.assume_role_policy, "aws:SourceAccount")
    error_message = "logging role must trust bedrock.amazonaws.com with SourceAccount condition"
  }
  assert {
    condition     = aws_iam_role.logging.permissions_boundary == var.role_boundary_arn
    error_message = "logging role must carry the ned-role-boundary"
  }
}

run "rejects_bad_account_id" {
  command = plan

  variables {
    account_id = "12345"
  }

  expect_failures = [var.account_id]
}

run "rejects_bad_log_retention" {
  command = plan

  variables {
    log_retention_days = 15
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_bad_user_boundary" {
  command = plan

  variables {
    user_boundary_arn = "ned-user-boundary"
  }

  expect_failures = [var.user_boundary_arn]
}

run "rejects_bad_role_boundary" {
  command = plan

  variables {
    role_boundary_arn = "ned-role-boundary"
  }

  expect_failures = [var.role_boundary_arn]
}

run "rejects_empty_model_list" {
  command = plan

  variables {
    allowed_model_ids = []
  }

  expect_failures = [var.allowed_model_ids]
}
