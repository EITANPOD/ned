output "topic_arn" {
  description = "ARN of the budget alerts SNS topic."
  value       = module.topic.topic_arn
}

output "budget_name" {
  description = "Name of the monthly budget."
  value       = aws_budgets_budget.monthly.name
}
