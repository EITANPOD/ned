variable "name" {
  description = "Budget name."
  type        = string
  default     = "ned-monthly"
}

variable "topic_name" {
  description = "SNS topic name for budget alerts."
  type        = string
  default     = "ned-budget-alerts"
}

variable "limit_usd" {
  description = "Monthly cost budget in USD. Alerts fire at 50% actual, 100% actual, 100% forecasted."
  type        = number
  default     = 10

  validation {
    condition     = var.limit_usd > 0
    error_message = "limit_usd must be greater than 0."
  }
}

variable "email" {
  description = "Email address that receives budget alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.email))
    error_message = "email must look like an email address."
  }
}

variable "account_id" {
  description = "AWS account ID allowed to publish to the alert topic (aws:SourceAccount condition)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "tags" {
  description = "Tags applied to the SNS topic."
  type        = map(string)
  default     = {}
}
