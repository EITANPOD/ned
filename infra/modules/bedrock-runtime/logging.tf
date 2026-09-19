resource "aws_cloudwatch_log_group" "this" {
  name              = "/ned/bedrock"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

locals {
  logging_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "bedrock.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${var.account_id}:*" }
      }
    }]
  })

  logging_write = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.this.arn}:log-stream:aws/bedrock/modelinvocations"
    }]
  })
}

# Plain resource, not the iam-role module: the trust policy is a single
# service-principal statement with SourceAccount/SourceArn conditions, and
# the module's trust_policy_permissions shape adds indirection without
# reducing this to less code.
resource "aws_iam_role" "logging" {
  name                 = "ned-bedrock-logging"
  assume_role_policy   = local.logging_trust
  permissions_boundary = var.role_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "logging_write" {
  name   = "ned-bedrock-logging-write"
  role   = aws_iam_role.logging.id
  policy = local.logging_write
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  depends_on = [aws_iam_role_policy.logging_write]

  logging_config {
    text_data_delivery_enabled      = true
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.this.name
      role_arn       = aws_iam_role.logging.arn
    }
  }
}
