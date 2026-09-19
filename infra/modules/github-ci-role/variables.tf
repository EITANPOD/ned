variable "name" {
  description = "Name of the apply role and of its inline policy (exact, no prefix)."
  type        = string
  default     = "ned-github-terraform"
}

variable "plan_role_name" {
  description = "Name of the main-branch plan role and of its inline policy (exact, no prefix)."
  type        = string
  default     = "ned-github-terraform-plan"
}

variable "read_role_name" {
  description = "Name of the PR (read-only) role and of its inline policy (exact, no prefix)."
  type        = string
  default     = "ned-github-terraform-read"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI roles, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) id; appears in the OIDC sub claim as owner@<id>."
  type        = number

  validation {
    condition     = var.github_owner_id > 0
    error_message = "github_owner_id must be a positive number."
  }
}

variable "github_repo_id" {
  description = "Numeric GitHub repository id; appears in the OIDC sub claim as repo@<id>."
  type        = number

  validation {
    condition     = var.github_repo_id > 0
    error_message = "github_repo_id must be a positive number."
  }
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket the CI roles read state from and stash plans in."
  type        = string

  validation {
    condition     = startswith(var.state_bucket_arn, "arn:aws:s3:::")
    error_message = "state_bucket_arn must be an S3 bucket ARN (arn:aws:s3:::<bucket>)."
  }
}

variable "aws_region" {
  description = "Region of the Ned resources the CI roles manage (log groups, SNS, SSM)."
  type        = string
}

variable "account_id" {
  description = "AWS account id; builds resource ARNs without a data source so the policies are plan-time known."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "tags" {
  description = "Tags for the OIDC provider and roles."
  type        = map(string)
  default     = {}
}
