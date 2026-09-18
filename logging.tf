resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/ned/bedrock"
  retention_in_days = var.log_retention_days
}

locals {
  bedrock_logging_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "bedrock.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${local.account_id}:*" }
      }
    }]
  })

  bedrock_logging_write = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.bedrock.arn}:log-stream:aws/bedrock/modelinvocations"
    }]
  })
}

resource "aws_iam_role" "bedrock_logging" {
  name               = "ned-bedrock-logging"
  assume_role_policy = local.bedrock_logging_trust
}

resource "aws_iam_role_policy" "bedrock_logging_write" {
  name   = "ned-bedrock-logging-write"
  role   = aws_iam_role.bedrock_logging.id
  policy = local.bedrock_logging_write
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  depends_on = [aws_iam_role_policy.bedrock_logging_write]

  logging_config {
    text_data_delivery_enabled      = true
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
  }
}
