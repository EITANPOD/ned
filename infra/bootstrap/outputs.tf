output "ci_role_arn" {
  description = "Set as GitHub repo variable AWS_TF_ROLE_ARN."
  value       = aws_iam_role.ci.arn
}

output "state_bucket" {
  description = "Set as GitHub repo variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.state.bucket
}

output "user_boundary_arn" {
  description = "Attach to every IAM user created by infra/aws."
  value       = aws_iam_policy.user_boundary.arn
}

output "role_boundary_arn" {
  description = "Attach to every IAM role created by infra/aws."
  value       = aws_iam_policy.role_boundary.arn
}
