locals {
  # GitHub embeds numeric ids in the OIDC sub claim: repo:<owner>@<owner_id>/<name>@<repo_id>:...
  # so a renamed or re-created repo cannot re-acquire these roles.
  subject = "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"

  # Not the module's enable_github_oidc: it writes `ForAllValues:StringEquals` on aud, which passes when
  # the key is absent. Explicit StringEquals aud + StringLike sub instead.
  trust = {
    for role, subs in {
      apply = ["repo:${local.subject}:environment:prod"]
      plan  = ["repo:${local.subject}:pull_request", "repo:${local.subject}:ref:refs/heads/main"]
      } : role => {
      GithubOidc = {
        actions    = ["sts:AssumeRoleWithWebIdentity"]
        principals = [{ type = "Federated", identifiers = [module.oidc_provider.arn] }]
        condition = [
          { test = "StringEquals", variable = "token.actions.githubusercontent.com:aud", values = ["sts.amazonaws.com"] },
          { test = "StringLike", variable = "token.actions.githubusercontent.com:sub", values = subs },
        ]
      }
    }
  }
}

module "oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "6.8.2"

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

# Apply role: only the `prod` GitHub environment (manual approval) can assume it.
module "role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.8.2"

  name                 = var.name
  use_name_prefix      = false
  max_session_duration = 3600

  trust_policy_permissions = local.trust.apply

  # Inline policy is named var.name (module uses the role name when use_name_prefix = false).
  create_inline_policy      = true
  inline_policy_permissions = local.ci_statements

  tags = var.tags
}

# Plan role: PR and main-branch plans; PR-authored Terraform never runs with write credentials.
module "plan_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.8.2"

  name                 = var.plan_role_name
  use_name_prefix      = false
  max_session_duration = 3600

  trust_policy_permissions = local.trust.plan

  create_inline_policy      = true
  inline_policy_permissions = local.plan_statements

  tags = var.tags
}
