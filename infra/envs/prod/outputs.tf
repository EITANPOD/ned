output "runtime_user_name" {
  description = "Name of the runtime IAM user."
  value       = module.bedrock_runtime.user_name
}

output "ssm_key_id_param" {
  description = "SSM parameter name holding the runtime access key ID."
  value       = module.bedrock_runtime.ssm_key_id_param
}

output "ssm_secret_param" {
  description = "SSM parameter name holding the runtime secret access key."
  value       = module.bedrock_runtime.ssm_secret_param
}

output "bedrock_log_group" {
  description = "CloudWatch log group receiving Bedrock invocation logs."
  value       = module.bedrock_runtime.log_group_name
}

output "budget_alerts_topic_arn" {
  description = "ARN of the budget alerts SNS topic."
  value       = module.budget_alerts.topic_arn
}

output "telegram_approver_url" {
  description = "Public Lambda function URL Telegram posts callback_query webhooks to."
  value       = module.telegram_approver.function_url
}
