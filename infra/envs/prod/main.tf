data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Created by infra/envs/bootstrap; the CI role may only create principals carrying them.
  # Split by principal type: users get Bedrock, roles get log writes under /ned/* plus the Telegram
  # approver's SSM reads (parameter/ned/telegram/*, parameter/ned/github/*) and kms:Decrypt via SSM.
  user_boundary_arn = "arn:aws:iam::${local.account_id}:policy/ned-user-boundary"
  role_boundary_arn = "arn:aws:iam::${local.account_id}:policy/ned-role-boundary"
}

module "bedrock_runtime" {
  source = "../../modules/bedrock-runtime"

  aws_region                    = var.aws_region
  account_id                    = local.account_id
  allowed_model_ids             = var.allowed_model_ids
  allowed_inference_profile_ids = var.allowed_inference_profile_ids
  user_boundary_arn             = local.user_boundary_arn
  role_boundary_arn             = local.role_boundary_arn
  log_retention_days            = var.log_retention_days
}

module "budget_alerts" {
  source = "../../modules/budget-alerts"

  account_id = local.account_id
  email      = var.budget_email
  limit_usd  = var.budget_limit_usd
}

module "telegram_approver" {
  source = "../../modules/telegram-approver"

  aws_region        = var.aws_region
  account_id        = local.account_id
  role_boundary_arn = local.role_boundary_arn
  repo              = "EITANPOD/ned"
}
