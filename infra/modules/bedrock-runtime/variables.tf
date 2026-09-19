variable "aws_region" {
  description = "Region for the Bedrock ARNs built by this module."
  type        = string
}

variable "account_id" {
  description = "AWS account ID (caller identity), used to scope Bedrock/log ARNs."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "user_name" {
  description = "Name of the runtime IAM user."
  type        = string
  default     = "ned-runtime"
}

variable "allowed_model_ids" {
  description = "Bedrock foundation model IDs the runtime may invoke."
  type        = list(string)

  validation {
    condition     = length(var.allowed_model_ids) > 0
    error_message = "allowed_model_ids must list at least one model."
  }
}

variable "allowed_inference_profile_ids" {
  description = "Cross-region inference profile IDs the runtime may invoke."
  type        = list(string)
}

variable "user_boundary_arn" {
  description = "Permissions boundary ARN attached to the runtime user."
  type        = string

  validation {
    condition     = startswith(var.user_boundary_arn, "arn:aws:iam::")
    error_message = "user_boundary_arn must be an IAM policy ARN (arn:aws:iam::...)."
  }
}

variable "role_boundary_arn" {
  description = "Permissions boundary ARN attached to the Bedrock logging role."
  type        = string

  validation {
    condition     = startswith(var.role_boundary_arn, "arn:aws:iam::")
    error_message = "role_boundary_arn must be an IAM policy ARN (arn:aws:iam::...)."
  }
}

variable "log_retention_days" {
  description = "Retention for Bedrock invocation logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs retention value (1, 3, 5, 7, 14, 30, ... 3653)."
  }
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path prefix for the runtime access key."
  type        = string
  default     = "/ned/runtime"
}

variable "tags" {
  description = "Tags applied to resources created by this module."
  type        = map(string)
  default     = {}
}
