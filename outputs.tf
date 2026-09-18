output "runtime_user_name" {
  value = aws_iam_user.runtime.name
}

output "ssm_key_id_param" {
  value = aws_ssm_parameter.runtime_key_id.name
}

output "ssm_secret_param" {
  value = aws_ssm_parameter.runtime_secret.name
}

output "bedrock_log_group" {
  value = aws_cloudwatch_log_group.bedrock.name
}

output "budget_alerts_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}
