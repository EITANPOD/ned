# State moves from the pre-restructure infra/aws root (same state key).
# Every infra/aws resource address maps here; see README for the table.

moved {
  from = aws_iam_user.runtime
  to   = module.bedrock_runtime.module.user.aws_iam_user.this[0]
}

moved {
  from = aws_iam_policy.runtime_bedrock
  to   = module.bedrock_runtime.aws_iam_policy.invoke
}

moved {
  from = aws_iam_user_policy_attachment.runtime_bedrock
  to   = module.bedrock_runtime.module.user.aws_iam_user_policy_attachment.additional["bedrock"]
}

moved {
  from = aws_iam_access_key.runtime
  to   = module.bedrock_runtime.module.user.aws_iam_access_key.this[0]
}

moved {
  from = aws_ssm_parameter.runtime_key_id
  to   = module.bedrock_runtime.aws_ssm_parameter.key_id
}

moved {
  from = aws_ssm_parameter.runtime_secret
  to   = module.bedrock_runtime.aws_ssm_parameter.secret
}

moved {
  from = aws_cloudwatch_log_group.bedrock
  to   = module.bedrock_runtime.aws_cloudwatch_log_group.this
}

moved {
  from = aws_iam_role.bedrock_logging
  to   = module.bedrock_runtime.aws_iam_role.logging
}

moved {
  from = aws_iam_role_policy.bedrock_logging_write
  to   = module.bedrock_runtime.aws_iam_role_policy.logging_write
}

moved {
  from = aws_bedrock_model_invocation_logging_configuration.this
  to   = module.bedrock_runtime.aws_bedrock_model_invocation_logging_configuration.this
}

moved {
  from = aws_sns_topic.budget_alerts
  to   = module.budget_alerts.module.topic.aws_sns_topic.this[0]
}

moved {
  from = aws_sns_topic_policy.budget_alerts
  to   = module.budget_alerts.module.topic.aws_sns_topic_policy.this[0]
}

moved {
  from = aws_budgets_budget.monthly
  to   = module.budget_alerts.aws_budgets_budget.monthly
}
