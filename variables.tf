variable "aws_region" {
  description = "Region for all Ned AWS resources."
  type        = string
  default     = "us-east-1"
}

variable "allowed_model_ids" {
  description = "Bedrock foundation model IDs the runtime may invoke. Cheapest Nova first; extend freely."
  type        = list(string)
  default = [
    "amazon.nova-micro-v1:0",
    "amazon.nova-lite-v1:0",
    "amazon.nova-2-lite-v1:0",
    "amazon.titan-embed-text-v2:0",
    "amazon.nova-2-multimodal-embeddings-v1:0",
  ]
}

variable "allowed_inference_profile_ids" {
  description = "Cross-region inference profile IDs the runtime may invoke (needed for models like nova-2-lite)."
  type        = list(string)
  default     = ["us.amazon.nova-2-lite-v1:0"]
}

// Consumed by budgets.tf, added in task 5.
variable "budget_email" { # tflint-ignore: terraform_unused_declarations
  description = "Email that receives budget alerts."
  type        = string
}

// Consumed by budgets.tf, added in task 5.
variable "budget_limit_usd" { # tflint-ignore: terraform_unused_declarations
  description = "Monthly cost budget in USD. Alerts fire at 50% actual, 100% actual, 100% forecasted."
  type        = number
  default     = 10
}

// Consumed by logging.tf, added in task 5.
variable "log_retention_days" { # tflint-ignore: terraform_unused_declarations
  description = "Retention for Bedrock invocation logs."
  type        = number
  default     = 14
}
