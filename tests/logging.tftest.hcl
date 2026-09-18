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

run "log_group_retention_and_text_only" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_group.bedrock.name == "/ned/bedrock" && aws_cloudwatch_log_group.bedrock.retention_in_days == 14
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
    condition     = strcontains(aws_iam_role.bedrock_logging.assume_role_policy, "bedrock.amazonaws.com") && strcontains(aws_iam_role.bedrock_logging.assume_role_policy, "aws:SourceAccount")
    error_message = "logging role must trust bedrock.amazonaws.com with SourceAccount condition"
  }
}
