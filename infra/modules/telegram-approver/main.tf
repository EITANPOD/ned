locals {
  name     = "ned-telegram-approver"
  log_name = "/ned/lambda/telegram-approver"
  # Created by the maintainer (never in state); the handler reads them at cold start.
  param_names = ["/ned/telegram/bot-token", "/ned/telegram/webhook-secret", "/ned/github/dispatch-token", "/ned/telegram/approver-id"]
  statements = [
    {
      Sid      = "ReadApproverParams"
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [for n in local.param_names : "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter${n}"]
    },
    {
      Sid       = "DecryptViaSsm"
      Effect    = "Allow"
      Action    = ["kms:Decrypt"]
      Resource  = "arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"
      Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } }
    },
    {
      Sid      = "WriteOwnLogs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:${local.log_name}:*"
    },
  ]
}

# Plan-time zip into the root's .build/; infra-aws stashes it with the tfplan (a saved plan does not re-read data sources).
data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/../../../apps/telegram-approver/handler.py"
  output_path = "${path.root}/.build/telegram-approver.zip"
}

resource "aws_iam_role" "this" {
  name                  = local.name
  permissions_boundary  = var.role_boundary_arn
  force_detach_policies = true
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = local.name
  role   = aws_iam_role.this.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.statements })
}

#trivy:ignore:AVD-AWS-0017 Logs hold request metadata only (no secrets are logged); a CMK costs ~$1/month.
resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_name
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name    = local.name
  role             = aws_iam_role.this.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 15
  memory_size      = 128
  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }
  environment {
    variables = {
      REPO                 = var.repo
      BOT_TOKEN_PARAM      = local.param_names[0]
      WEBHOOK_SECRET_PARAM = local.param_names[1]
      DISPATCH_TOKEN_PARAM = local.param_names[2]
      APPROVER_ID_PARAM    = local.param_names[3]
    }
  }
  tags = var.tags
}

# Telegram cannot sign webhooks; the handler rejects any request without the secret header.
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"
}

# Public function URLs need both permissions (InvokeFunctionUrl + InvokeFunction via the URL).
resource "aws_lambda_permission" "url" {
  statement_id           = "FunctionUrlPublic"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.this.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "invoke" {
  statement_id             = "FunctionUrlInvoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.this.function_name
  principal                = "*"
  invoked_via_function_url = true
}
