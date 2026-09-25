output "function_url" {
  description = "Public Lambda function URL Telegram posts webhooks to."
  value       = aws_lambda_function_url.this.function_url
}
