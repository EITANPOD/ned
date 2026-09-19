# jsonencode (not aws_iam_policy_document) so mock_provider tests can assert on content.
locals {
  invoke_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeAllowedModels"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
        ]
        Resource = concat(
          [for m in var.allowed_model_ids : "arn:aws:bedrock:*::foundation-model/${m}"],
          [for p in var.allowed_inference_profile_ids : "arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/${p}"],
        )
      },
      {
        Sid      = "DiscoverModels"
        Effect   = "Allow"
        Action   = ["bedrock:ListFoundationModels", "bedrock:ListInferenceProfiles"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_policy" "invoke" {
  name   = "${var.user_name}-bedrock"
  policy = local.invoke_policy
  tags   = var.tags
}

module "user" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-user"
  version = "6.8.2"

  name                 = var.user_name
  permissions_boundary = var.user_boundary_arn
  create_login_profile = false
  create_access_key    = true
  policies             = { bedrock = aws_iam_policy.invoke.arn }
  tags                 = var.tags
}

# Read by the deploy job (Phase 8) via the CI role; never printed.
resource "aws_ssm_parameter" "key_id" {
  name  = "${var.ssm_prefix}/aws_access_key_id"
  type  = "String"
  value = module.user.access_key_id
  tags  = var.tags
}

resource "aws_ssm_parameter" "secret" {
  name  = "${var.ssm_prefix}/aws_secret_access_key"
  type  = "SecureString"
  value = module.user.access_key_secret
  tags  = var.tags
}
