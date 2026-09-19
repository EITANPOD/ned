output "user_name" {
  description = "Name of the runtime IAM user."
  value       = module.user.name
}

output "ssm_key_id_param" {
  description = "SSM parameter name holding the runtime access key ID."
  value       = aws_ssm_parameter.key_id.name
}

output "ssm_secret_param" {
  description = "SSM parameter name holding the runtime secret access key."
  value       = aws_ssm_parameter.secret.name
}

output "log_group_name" {
  description = "CloudWatch log group receiving Bedrock invocation logs."
  value       = aws_cloudwatch_log_group.this.name
}
