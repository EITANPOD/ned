data "aws_caller_identity" "current" {}

# --- Terraform remote state -------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132 SSE-S3 is sufficient: private, versioned, single-account state bucket. CMK adds ~$1/month with no access-control gain. Upgrade path: sse_algorithm = "aws:kms" + kms_master_key_id.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-plans"
    status = "Enabled"

    filter {
      prefix = "plans/"
    }

    expiration {
      days = 1
    }
  }
}

# --- GitHub OIDC -> AWS --------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Policies are plain jsonencode() (not aws_iam_policy_document data sources) so
# `terraform test` with mock_provider can assert on their content.
# GitHub now embeds numeric ids in the OIDC sub claim, so the subject is pinned as
# repo:<owner>@<owner_id>/<name>@<repo_id>:* — a rename cannot re-acquire this role.
locals {
  ci_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}:*" }
      }
    }]
  })
}

resource "aws_iam_role" "ci" {
  name                 = "ned-github-terraform"
  assume_role_policy   = local.ci_trust_policy
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ci" {
  name   = "ned-github-terraform"
  role   = aws_iam_role.ci.id
  policy = local.ci_permissions_policy
}
