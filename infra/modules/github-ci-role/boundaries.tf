# Permissions boundaries attached (by infra/envs/prod) to every IAM principal Ned's CI creates.
# The CI role may only create a principal that carries the matching boundary, so even a
# rewritten inline policy cannot exceed it. They are split by principal type on purpose:
# users get Bedrock, roles get log writes under /ned/* plus the Telegram approver's SSM reads
# (parameter/ned/telegram/*, parameter/ned/github/*) and kms:Decrypt scoped to those reads via
# kms:ViaService=ssm. CI can set an arbitrary trust policy on a ned-* role, so a role assumed by
# an outside party must gain nothing beyond that: writing /ned/* logs and reading those SSM params.
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
      {
        Sid    = "NedApproverSecrets"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/ned/telegram/*",
          "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/ned/github/*",
        ]
      },
      {
        Sid       = "NedDecryptViaSsm"
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = "arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"
        Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } }
      },
    ]
  })
}
