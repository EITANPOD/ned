# Permissions boundaries attached (by infra/envs/prod) to every IAM principal Ned's CI creates.
# The CI role may only create a principal that carries the matching boundary, so even a
# rewritten inline policy cannot exceed it. They are split by principal type on purpose:
# users get Bedrock, roles get log writes only. CI can set an arbitrary trust policy on a
# ned-* role, so a role assumed by an outside party must gain nothing beyond writing logs.
resource "aws_iam_policy" "user_boundary" {
  name = "ned-user-boundary"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
          "bedrock:ListFoundationModels",
          "bedrock:ListInferenceProfiles",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_policy" "role_boundary" {
  name = "ned-role-boundary"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "NedLogsWrite"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ned/*"
      },
    ]
  })
}
