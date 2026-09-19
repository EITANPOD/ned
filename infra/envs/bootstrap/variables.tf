variable "github_repo" {
  description = "GitHub repo allowed to assume the CI role, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) id; appears in the OIDC sub claim as owner@<id>."
  type        = number
}

variable "github_repo_id" {
  description = "Numeric GitHub repository id; appears in the OIDC sub claim as repo@<id>."
  type        = number
}

variable "aws_region" {
  description = "Region for all Ned AWS resources."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}
