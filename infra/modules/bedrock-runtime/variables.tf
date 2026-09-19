variable "aws_region" {
  description = "Region for the Bedrock ARNs built by this module."
  type        = string
}

variable "account_id" {
  description = "AWS account ID (caller identity), used to scope Bedrock/log ARNs."
  type        = string
}

variable "user_name" {
  description = "Name of the runtime IAM user."
  type        = string
  default     = "ned-runtime"
}

variable "allowed_model_ids" {
  description = "Bedrock foundation model IDs the runtime may invoke."
  type        = list(string)
}

variable "allowed_inference_profile_ids" {
  description = "Cross-region inference profile IDs the runtime may invoke."
  type        = list(string)
}

variable "user_boundary_arn" {
  description = "Permissions boundary ARN attached to the runtime user."
  type        = string
}

variable "role_boundary_arn" {
  description = "Permissions boundary ARN attached to the Bedrock logging role."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for Bedrock invocation logs."
  type        = number
  default     = 14
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
