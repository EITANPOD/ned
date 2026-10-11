variable "aws_region" {
  description = "Region for the Lambda and the ARNs this module builds."
  type        = string
}

variable "account_id" {
  description = "AWS account ID, used to scope SSM/KMS/log ARNs."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "role_boundary_arn" {
  description = "Permissions boundary ARN attached to the Lambda's execution role."
  type        = string

  validation {
    condition     = startswith(var.role_boundary_arn, "arn:aws:iam::")
    error_message = "role_boundary_arn must be an IAM policy ARN (arn:aws:iam::...)."
  }
}

variable "repo" {
  description = "GitHub repo the approver dispatches workflow runs to, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.repo))
    error_message = "repo must look like owner/name."
  }
}

variable "log_retention_days" {
  description = "Retention for the Lambda's CloudWatch logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs retention value (1, 3, 5, 7, 14, 30, ... 3653)."
  }
}

variable "tags" {
  description = "Tags applied to resources created by this module."
  type        = map(string)
  default     = {}
}
