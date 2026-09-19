output "ci_role_arn" {
  description = "Apply role ARN. Set as GitHub repo variable AWS_TF_ROLE_ARN."
  value       = module.github_ci_role.role_arn
}

output "plan_role_arn" {
  description = "Main-branch plan role ARN. Set as GitHub repo variable AWS_TF_PLAN_ROLE_ARN."
  value       = module.github_ci_role.plan_role_arn
}

output "read_role_arn" {
  description = "PR read-only role ARN. Set as GitHub repo variable AWS_TF_READ_ROLE_ARN."
  value       = module.github_ci_role.read_role_arn
}

output "state_bucket" {
  description = "Set as GitHub repo variable TF_STATE_BUCKET."
  value       = module.state_bucket.s3_bucket_id
}

output "user_boundary_arn" {
  description = "Attach to every IAM user created by infra/envs/prod."
  value       = module.github_ci_role.user_boundary_arn
}

output "role_boundary_arn" {
  description = "Attach to every IAM role created by infra/envs/prod."
  value       = module.github_ci_role.role_boundary_arn
}
