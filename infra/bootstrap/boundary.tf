# Permissions boundary attached (by infra/aws) to every IAM principal Ned's CI creates.
# The CI role may only create users/roles that carry this boundary, so even a
# rewritten inline policy cannot exceed it.
resource "aws_iam_policy" "boundary" {
  name = "ned-permissions-boundary"
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
      {
        Sid      = "NedLogsWrite"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ned/*"
      },
    ]
  })
}
