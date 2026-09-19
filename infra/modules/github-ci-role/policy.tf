# Statements in the official iam-role `inline_policy_permissions` shape; the map key is the Sid.
locals {
  iam_arn   = "arn:aws:iam::${var.account_id}"
  state_arn = var.state_bucket_arn

  # Apply role: least privilege for what infra/envs/prod manages, everything scoped to ned-* names.
  # Carried over statement-for-statement from infra/bootstrap/ci_role_policy.tf.
  ci_statements = {
    StateBucketList = {
      actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
      resources = [local.state_arn]
    }
    # aws/ = the infra/envs/prod state key (kept from the old infra/aws root); plans/ = tfplan handoff between the plan and apply jobs.
    StateObjects = {
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${local.state_arn}/aws/*", "${local.state_arn}/plans/*"]
    }
    # Principals may only be created with the matching boundary attached.
    NedIamCreateUserWithBoundary = {
      actions   = ["iam:CreateUser", "iam:PutUserPermissionsBoundary"]
      resources = ["${local.iam_arn}:user/ned-*"]
      condition = [{ test = "StringEquals", variable = "iam:PermissionsBoundary", values = [aws_iam_policy.user_boundary.arn] }]
    }
    NedIamCreateRoleWithBoundary = {
      actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
      resources = ["${local.iam_arn}:role/ned-*"]
      condition = [{ test = "StringEquals", variable = "iam:PermissionsBoundary", values = [aws_iam_policy.role_boundary.arn] }]
    }
    NedIamManage = {
      actions = [
        "iam:DeleteUser", "iam:GetUser", "iam:TagUser", "iam:UntagUser", "iam:ListGroupsForUser",
        "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:ListAccessKeys", "iam:UpdateAccessKey",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
        "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
        "iam:ListAttachedUserPolicies", "iam:ListUserPolicies",
        "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      ]
      resources = [
        "${local.iam_arn}:user/ned-*",
        "${local.iam_arn}:policy/ned-*",
        "${local.iam_arn}:role/ned-*",
      ]
    }
    NedIamAttachScopedPolicies = {
      actions   = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
      resources = ["${local.iam_arn}:user/ned-*"]
      condition = [{ test = "ArnLike", variable = "iam:PolicyARN", values = ["${local.iam_arn}:policy/ned-*"] }]
    }
    PassRoleToServices = {
      actions   = ["iam:PassRole"]
      resources = ["${local.iam_arn}:role/ned-*"]
      condition = [{ test = "StringEquals", variable = "iam:PassedToService", values = ["bedrock.amazonaws.com", "lambda.amazonaws.com"] }]
    }
    # The CI roles must never be changeable by CI: otherwise apply could rewrite itself, or widen the
    # unbounded read/plan roles that PRs and main assume. Deterministic ARNs, not module outputs (cycle).
    DenySelfModifyAndBoundaryRemoval = {
      effect    = "Deny"
      actions   = ["iam:*"]
      resources = [for n in [var.name, var.plan_role_name, var.read_role_name] : "${local.iam_arn}:role/${n}"]
    }
    DenyBoundaryRemoval = {
      effect    = "Deny"
      actions   = ["iam:DeleteUserPermissionsBoundary", "iam:DeleteRolePermissionsBoundary"]
      resources = ["*"]
    }
    # policy/ned-* above would otherwise let CI rewrite the boundaries themselves.
    DenyBoundaryPolicyEdits = {
      effect = "Deny"
      actions = [
        "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion",
        "iam:DeletePolicy", "iam:TagPolicy", "iam:UntagPolicy",
      ]
      resources = [aws_iam_policy.user_boundary.arn, aws_iam_policy.role_boundary.arn]
    }
    Budgets = {
      actions = [
        "budgets:ViewBudget", "budgets:ModifyBudget",
        "budgets:TagResource", "budgets:UntagResource", "budgets:ListTagsForResource",
      ]
      resources = ["arn:aws:budgets::${var.account_id}:budget/ned-*"]
    }
    BedrockLoggingConfig = {
      actions = [
        "bedrock:PutModelInvocationLoggingConfiguration",
        "bedrock:GetModelInvocationLoggingConfiguration",
        "bedrock:DeleteModelInvocationLoggingConfiguration",
      ]
      resources = ["*"]
    }
    LogsDescribe = {
      actions   = ["logs:DescribeLogGroups"]
      resources = ["*"]
    }
    NedLogGroups = {
      actions = [
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
        "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
      ]
      resources = ["arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ned/*"]
    }
    NedSns = {
      actions = [
        "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
        "sns:GetDataProtectionPolicy",
        "sns:ListTagsForResource", "sns:TagResource", "sns:UntagResource",
        "sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:ListSubscriptionsByTopic",
      ]
      resources = ["arn:aws:sns:${var.aws_region}:${var.account_id}:ned-*"]
    }
    NedSsmParams = {
      actions = [
        "ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter",
        "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
      ]
      resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/ned/*"]
    }
    SsmDescribe = {
      actions   = ["ssm:DescribeParameters"]
      resources = ["*"]
    }
    # Telegram approver (infra/modules/telegram-approver). Function URL + resource policy are sub-resources of the function ARN.
    NedLambda = {
      actions = [
        "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
        "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:ListVersionsByFunction",
        "lambda:GetFunctionCodeSigningConfig", "lambda:GetRuntimeManagementConfig",
        "lambda:CreateFunctionUrlConfig", "lambda:GetFunctionUrlConfig", "lambda:UpdateFunctionUrlConfig",
        "lambda:DeleteFunctionUrlConfig",
        "lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy",
        "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
      ]
      resources = ["arn:aws:lambda:${var.aws_region}:${var.account_id}:function:ned-*"]
    }
  }

  # Read role (PRs): refresh reads only, no S3 writes of any kind (PR plans run -lock=false, never stash).
  read_statements = {
    StateBucketList = {
      actions   = ["s3:ListBucket"]
      resources = [local.state_arn]
    }
    StateRead = {
      actions   = ["s3:GetObject"]
      resources = ["${local.state_arn}/aws/*"]
    }
    NedIamRead = {
      actions = ["iam:Get*", "iam:List*"]
      resources = [
        "${local.iam_arn}:user/ned-*",
        "${local.iam_arn}:policy/ned-*",
        "${local.iam_arn}:role/ned-*",
      ]
    }
    LogsDescribe = {
      actions   = ["logs:DescribeLogGroups"]
      resources = ["*"]
    }
    NedLogGroupTags = {
      actions   = ["logs:ListTagsForResource"]
      resources = ["arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ned/*"]
    }
    NedSnsRead = {
      actions   = ["sns:Get*", "sns:List*"]
      resources = ["arn:aws:sns:${var.aws_region}:${var.account_id}:ned-*"]
    }
    NedSsmRead = {
      actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
      resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/ned/*"]
    }
    SsmDescribe = {
      actions   = ["ssm:DescribeParameters"]
      resources = ["*"]
    }
    BudgetsRead = {
      actions   = ["budgets:View*", "budgets:ListTagsForResource"]
      resources = ["arn:aws:budgets::${var.account_id}:budget/ned-*"]
    }
    BedrockLoggingRead = {
      actions   = ["bedrock:GetModelInvocationLoggingConfiguration"]
      resources = ["*"]
    }
    NedLambdaRead = {
      actions   = ["lambda:Get*", "lambda:List*"]
      resources = ["arn:aws:lambda:${var.aws_region}:${var.account_id}:function:ned-*"]
    }
    # Approver secrets (telegram-approver): Terraform never manages them, so refresh never needs them.
    # Without this a PR plan could print the webhook secret and forge a Telegram approval.
    DenyApproverSecrets = {
      effect  = "Deny"
      actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      resources = [
        "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/ned/telegram/*",
        "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/ned/github/*",
      ]
    }
  }

  # Plan role (main only): the same reads plus the state lock and the plans/ stash for dispatch applies.
  plan_statements = merge(local.read_statements, {
    StateLock = {
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${local.state_arn}/aws/*.tflock"]
    }
    PlanStash = {
      actions   = ["s3:PutObject"]
      resources = ["${local.state_arn}/plans/*"]
    }
  })
}
