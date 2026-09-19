# Child-module resources are not addressable from a test, and under mock_provider the official
# module's aws_iam_policy_document renders synthetic JSON. So these assert on the statement maps
# (locals) the module is fed; the module renders each map entry 1:1 into a policy statement.
mock_provider "aws" {
  # Synthetic default JSON fails aws_iam_role_policy validation; any valid document will do.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "tls" {}

variables {
  github_repo      = "EITANPOD/ned"
  github_owner_id  = 164246517
  github_repo_id   = 1376066666
  state_bucket_arn = "arn:aws:s3:::ned-tfstate-test"
  aws_region       = "us-east-1"
  account_id       = "123456789012"
}

run "names_are_exact" {
  command = apply

  assert {
    condition     = aws_iam_policy.user_boundary.name == "ned-user-boundary" && aws_iam_policy.role_boundary.name == "ned-role-boundary"
    error_message = "boundary policies must be ned-user-boundary / ned-role-boundary"
  }
  assert {
    condition     = module.role.name == "ned-github-terraform" && module.plan_role.name == "ned-github-terraform-plan" && module.read_role.name == "ned-github-terraform-read"
    error_message = "role names must be exact (use_name_prefix = false)"
  }
}

run "apply_policy_keeps_every_bootstrap_sid" {
  command = apply

  assert {
    condition = sort(keys(local.ci_statements)) == sort([
      "StateBucketList", "StateObjects", "NedIamCreateUserWithBoundary", "NedIamCreateRoleWithBoundary",
      "NedIamManage", "NedIamAttachScopedPolicies", "PassRoleToServices", "DenySelfModifyAndBoundaryRemoval",
      "DenyBoundaryRemoval", "DenyBoundaryPolicyEdits", "Budgets", "BedrockLoggingConfig", "LogsDescribe",
      "NedLogGroups", "NedSns", "NedSsmParams", "SsmDescribe", "NedLambda",
    ])
    error_message = "apply policy must carry exactly the bootstrap statements"
  }
  assert {
    condition = local.ci_statements.DenySelfModifyAndBoundaryRemoval.effect == "Deny" && local.ci_statements.DenySelfModifyAndBoundaryRemoval.resources == [
      "arn:aws:iam::123456789012:role/ned-github-terraform",
      "arn:aws:iam::123456789012:role/ned-github-terraform-plan",
      "arn:aws:iam::123456789012:role/ned-github-terraform-read",
    ]
    error_message = "apply role must deny iam:* on all three CI roles"
  }
  assert {
    condition = local.ci_statements.NedIamManage.actions == [
      "iam:DeleteUser", "iam:GetUser", "iam:TagUser", "iam:UntagUser", "iam:ListGroupsForUser",
      "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:ListAccessKeys", "iam:UpdateAccessKey",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
      "iam:ListAttachedUserPolicies", "iam:ListUserPolicies",
      "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    error_message = "NedIamManage must match infra/bootstrap exactly"
  }
  assert {
    condition     = local.ci_statements.DenyBoundaryPolicyEdits.effect == "Deny" && contains(local.ci_statements.DenyBoundaryPolicyEdits.actions, "iam:CreatePolicyVersion")
    error_message = "apply role must be denied editing the boundary policies"
  }
  assert {
    condition     = local.ci_statements.DenyBoundaryRemoval.effect == "Deny"
    error_message = "apply role must deny removing permissions boundaries"
  }
}

run "apply_policy_conditions" {
  command = apply

  assert {
    condition     = one(local.ci_statements.NedIamCreateUserWithBoundary.condition).variable == "iam:PermissionsBoundary" && one(local.ci_statements.NedIamCreateUserWithBoundary.condition).values == [aws_iam_policy.user_boundary.arn]
    error_message = "CreateUser must require the user boundary"
  }
  assert {
    condition     = one(local.ci_statements.NedIamCreateRoleWithBoundary.condition).values == [aws_iam_policy.role_boundary.arn]
    error_message = "CreateRole must require the role boundary"
  }
  assert {
    condition     = one(local.ci_statements.PassRoleToServices.condition).variable == "iam:PassedToService" && contains(one(local.ci_statements.PassRoleToServices.condition).values, "bedrock.amazonaws.com")
    error_message = "PassRole must be limited to bedrock.amazonaws.com (and lambda.amazonaws.com)"
  }
  assert {
    condition     = one(local.ci_statements.NedIamAttachScopedPolicies.condition).variable == "iam:PolicyARN"
    error_message = "AttachUserPolicy must be conditioned on iam:PolicyARN"
  }
}

run "no_wildcard_actions" {
  command = apply

  assert {
    condition     = alltrue([for s in concat(values(local.ci_statements), values(local.plan_statements), values(local.read_statements)) : !contains(s.actions, "*")])
    error_message = "no statement may grant Action:*"
  }
}

run "trust_is_exact" {
  command = apply

  assert {
    condition     = one(local.trust.apply.GithubOidc.condition[1].values) == "repo:EITANPOD@164246517/ned@1376066666:environment:prod"
    error_message = "apply role must trust only the prod environment of this repo"
  }
  assert {
    condition     = local.trust.plan.GithubOidc.condition[1].values == ["repo:EITANPOD@164246517/ned@1376066666:ref:refs/heads/main"]
    error_message = "plan role must trust only main of this repo"
  }
  assert {
    condition     = local.trust.read.GithubOidc.condition[1].values == ["repo:EITANPOD@164246517/ned@1376066666:pull_request"]
    error_message = "read role must trust only PRs of this repo"
  }
  assert {
    condition = alltrue([for t in values(local.trust) : (
      t.GithubOidc.condition[0].test == "StringEquals" &&
      t.GithubOidc.condition[0].variable == "token.actions.githubusercontent.com:aud" &&
      t.GithubOidc.condition[0].values == ["sts.amazonaws.com"] &&
      t.GithubOidc.condition[1].test == "StringLike" &&
      t.GithubOidc.condition[1].variable == "token.actions.githubusercontent.com:sub" &&
      length(regexall("ForAllValues|ForAnyValue", jsonencode(t))) == 0
    )])
    error_message = "trust must use StringEquals on aud and StringLike on sub, never ForAllValues"
  }
}

run "read_role_is_read_only" {
  command = apply

  assert {
    condition = sort(keys(local.read_statements)) == sort([
      "StateBucketList", "StateRead", "NedIamRead", "LogsDescribe", "NedLogGroupTags", "NedSnsRead",
      "NedSsmRead", "SsmDescribe", "BudgetsRead", "BedrockLoggingRead", "NedLambdaRead", "DenyApproverSecrets",
    ])
    error_message = "read role statement set drifted"
  }
  assert {
    condition = length([
      for a in flatten([for s in values(local.read_statements) : s.actions]) : a
      if length(regexall("^[a-z0-9]+:(Create|Put|Delete|Attach|Detach|Update|Set|Modify|Tag|Untag|Pass|Add|Remove|\\*)", a)) > 0
    ]) == 0
    error_message = "read role must have no write actions (incl. s3:Put*/s3:Delete*)"
  }
}

run "plan_role_writes_only_lock_and_stash" {
  command = apply

  assert {
    condition = sort([
      for k, s in local.plan_statements : k
      if length([for a in s.actions : a if length(regexall("^[a-z0-9]+:(Create|Put|Delete|Attach|Detach|Update|Set|Modify|Tag|Untag|Pass|Add|Remove|\\*)", a)) > 0]) > 0
    ]) == tolist(["PlanStash", "StateLock"])
    error_message = "plan role may only write the state lockfile and plans/*"
  }
  assert {
    condition     = local.plan_statements.PlanStash.resources == ["arn:aws:s3:::ned-tfstate-test/plans/*"] && local.plan_statements.StateLock.resources == ["arn:aws:s3:::ned-tfstate-test/aws/*.tflock"]
    error_message = "plan role S3 writes must be limited to plans/* and the state lockfile"
  }
  assert {
    condition     = sort(keys(local.plan_statements)) == sort(concat(keys(local.read_statements), ["PlanStash", "StateLock"]))
    error_message = "plan role must be the read set plus the lock and stash statements"
  }
}

run "lambda_permissions" {
  command = apply

  assert {
    condition     = local.ci_statements["NedLambda"].resources == ["arn:aws:lambda:${var.aws_region}:${var.account_id}:function:ned-*"]
    error_message = "apply role Lambda statement must be scoped to function:ned-*"
  }
  assert {
    condition     = contains(local.ci_statements["PassRoleToServices"].condition[0].values, "lambda.amazonaws.com") && contains(local.ci_statements["PassRoleToServices"].condition[0].values, "bedrock.amazonaws.com") && length(local.ci_statements["PassRoleToServices"].condition[0].values) == 2
    error_message = "PassRole must allow exactly bedrock + lambda"
  }
  assert {
    condition     = local.read_statements["NedLambdaRead"].actions == ["lambda:Get*", "lambda:List*"]
    error_message = "read role gets Lambda reads only"
  }
  assert {
    condition     = strcontains(aws_iam_policy.role_boundary.policy, "parameter/ned/telegram/*") && strcontains(aws_iam_policy.role_boundary.policy, "kms:ViaService")
    error_message = "role boundary must allow the approver's SSM reads (KMS via SSM only)"
  }
}

run "read_and_plan_roles_deny_approver_secrets" {
  command = apply

  assert {
    condition = local.read_statements.DenyApproverSecrets.effect == "Deny" && local.read_statements.DenyApproverSecrets.resources == [
      "arn:aws:ssm:us-east-1:123456789012:parameter/ned/telegram/*",
      "arn:aws:ssm:us-east-1:123456789012:parameter/ned/github/*",
    ]
    error_message = "read role must deny reading the approver's SSM secrets"
  }
  assert {
    condition     = contains(keys(local.plan_statements), "DenyApproverSecrets") && local.plan_statements.DenyApproverSecrets.effect == "Deny"
    error_message = "plan role must inherit the approver-secrets deny from the read statements"
  }
  assert {
    condition     = !contains(keys(local.ci_statements), "DenyApproverSecrets")
    error_message = "apply role is unchanged (R5): it keeps its existing access to the approver secrets"
  }
}

run "rejects_bad_repo" {
  command = plan

  variables {
    github_repo = "not-a-repo"
  }

  expect_failures = [var.github_repo]
}
