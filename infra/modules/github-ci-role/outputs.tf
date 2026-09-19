output "role_arn" {
  description = "Apply role ARN (GitHub variable AWS_TF_ROLE_ARN)."
  value       = module.role.arn
}

output "plan_role_arn" {
  description = "Read-only plan role ARN for PR and main-branch plans."
  value       = module.plan_role.arn
}

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  value       = module.oidc_provider.arn
}

output "user_boundary_arn" {
  description = "Attach to every IAM user created by CI."
  value       = aws_iam_policy.user_boundary.arn
}

output "role_boundary_arn" {
  description = "Attach to every IAM role created by CI."
  value       = aws_iam_policy.role_boundary.arn
}
