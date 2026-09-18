locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Least-privilege for what infra/aws manages. Everything scoped to ned-* names.
# infra/bootstrap itself is applied locally, so the CI role has no grants on
# the state bucket config, the OIDC provider, or itself.
locals {
  ci_permissions_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        # aws/ = the infra/aws state key; plans/ = tfplan handoff between the
        # plan and apply jobs (infra-aws.yml), expired after 1 day by lifecycle.
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.state.arn}/aws/*", "${aws_s3_bucket.state.arn}/plans/*"]
      },
      {
        # Principals may only be created with the permissions boundary attached.
        Sid    = "NedIamCreateWithBoundary"
        Effect = "Allow"
        Action = ["iam:CreateUser", "iam:CreateRole", "iam:PutUserPermissionsBoundary", "iam:PutRolePermissionsBoundary"]
        Resource = [
          "arn:aws:iam::${local.account_id}:user/ned-*",
          "arn:aws:iam::${local.account_id}:role/ned-*",
        ]
        Condition = {
          StringEquals = { "iam:PermissionsBoundary" = aws_iam_policy.boundary.arn }
        }
      },
      {
        Sid    = "NedIamManage"
        Effect = "Allow"
        Action = [
          "iam:DeleteUser", "iam:GetUser", "iam:TagUser", "iam:UntagUser", "iam:ListGroupsForUser",
          "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:ListAccessKeys", "iam:UpdateAccessKey",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
          "iam:ListAttachedUserPolicies", "iam:ListUserPolicies",
          "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:user/ned-*",
          "arn:aws:iam::${local.account_id}:policy/ned-*",
          "arn:aws:iam::${local.account_id}:role/ned-*",
        ]
      },
      {
        Sid      = "NedIamAttachScopedPolicies"
        Effect   = "Allow"
        Action   = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
        Resource = "arn:aws:iam::${local.account_id}:user/ned-*"
        Condition = {
          ArnLike = { "iam:PolicyARN" = "arn:aws:iam::${local.account_id}:policy/ned-*" }
        }
      },
      {
        Sid      = "PassRoleToBedrockOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/ned-*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "bedrock.amazonaws.com" }
        }
      },
      {
        # The CI role must never be able to change itself or strip the boundary.
        Sid    = "DenySelfModifyAndBoundaryRemoval"
        Effect = "Deny"
        Action = [
          "iam:*",
        ]
        Resource = aws_iam_role.ci.arn
      },
      {
        Sid      = "DenyBoundaryRemoval"
        Effect   = "Deny"
        Action   = ["iam:DeleteUserPermissionsBoundary", "iam:DeleteRolePermissionsBoundary"]
        Resource = "*"
      },
      {
        Sid    = "Budgets"
        Effect = "Allow"
        Action = [
          "budgets:ViewBudget", "budgets:ModifyBudget",
          "budgets:TagResource", "budgets:UntagResource", "budgets:ListTagsForResource",
        ]
        Resource = "arn:aws:budgets::${local.account_id}:budget/ned-*"
      },
      {
        Sid    = "BedrockLoggingConfig"
        Effect = "Allow"
        Action = [
          "bedrock:PutModelInvocationLoggingConfiguration",
          "bedrock:GetModelInvocationLoggingConfiguration",
          "bedrock:DeleteModelInvocationLoggingConfiguration",
        ]
        Resource = "*"
      },
      {
        Sid      = "LogsDescribe"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "NedLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ned/*"
      },
      {
        Sid    = "NedSns"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
          "sns:GetDataProtectionPolicy",
          "sns:ListTagsForResource", "sns:TagResource", "sns:UntagResource",
          "sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:ListSubscriptionsByTopic",
        ]
        Resource = "arn:aws:sns:${var.aws_region}:${local.account_id}:ned-*"
      },
      {
        Sid    = "NedSsmParams"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter",
          "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/ned/*"
      },
      {
        Sid      = "SsmDescribe"
        Effect   = "Allow"
        Action   = "ssm:DescribeParameters"
        Resource = "*"
      },
    ]
  })
}
