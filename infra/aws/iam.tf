resource "aws_iam_user" "runtime" {
  name                 = "ned-runtime"
  permissions_boundary = local.user_boundary_arn
}

# jsonencode (not aws_iam_policy_document) so mock_provider tests can assert on content.
locals {
  runtime_bedrock_policy = jsonencode({
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
          [for p in var.allowed_inference_profile_ids : "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${p}"],
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

resource "aws_iam_policy" "runtime_bedrock" {
  name   = "ned-runtime-bedrock"
  policy = local.runtime_bedrock_policy
}

resource "aws_iam_user_policy_attachment" "runtime_bedrock" {
  user       = aws_iam_user.runtime.name
  policy_arn = aws_iam_policy.runtime_bedrock.arn
}

resource "aws_iam_access_key" "runtime" {
  user = aws_iam_user.runtime.name
}

# Read by the deploy job (Phase 8) via the CI role; never printed.
resource "aws_ssm_parameter" "runtime_key_id" {
  name  = "/ned/runtime/aws_access_key_id"
  type  = "String"
  value = aws_iam_access_key.runtime.id
}

resource "aws_ssm_parameter" "runtime_secret" {
  name  = "/ned/runtime/aws_secret_access_key"
  type  = "SecureString"
  value = aws_iam_access_key.runtime.secret
}
