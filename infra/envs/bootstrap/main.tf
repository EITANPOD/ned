data "aws_caller_identity" "current" {}

# Terraform remote state. Every s3-bucket module feature not listed here is off by the module's own
# defaults (no ACL, bucket policy, ownership controls, logging, CORS, object lock), matching the live
# bucket, so the migration adds nothing.
#trivy:ignore:AVD-AWS-0132 SSE-S3 is sufficient: private, versioned, single-account state bucket. CMK adds ~$1/month with no access-control gain. Upgrade path: sse_algorithm = "aws:kms" + kms_master_key_id.
module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.16.1"

  bucket = var.state_bucket_name

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = { apply_server_side_encryption_by_default = { sse_algorithm = "AES256" } }
  }

  # attach_public_policy is the module's gate for creating the public access block (misnamed upstream).
  attach_public_policy    = true
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle_rule = [
    {
      id         = "expire-plans"
      enabled    = true
      filter     = { prefix = "plans/" }
      expiration = { days = 1 }
      # Bucket is versioned: `expiration` only writes a delete marker, so the
      # stashed plan would live on as a noncurrent version.
      noncurrent_version_expiration = { days = 1 }
    },
    {
      # AWS rejects `days` and `expired_object_delete_marker` in one expiration block.
      id         = "purge-plan-delete-markers"
      enabled    = true
      filter     = { prefix = "plans/" }
      expiration = { expired_object_delete_marker = true }
    },
  ]
}

# GitHub OIDC provider, the read/plan/apply CI roles and the two permissions boundaries.
module "github_ci_role" {
  source = "../../modules/github-ci-role"

  github_repo      = var.github_repo
  github_owner_id  = var.github_owner_id
  github_repo_id   = var.github_repo_id
  state_bucket_arn = module.state_bucket.s3_bucket_arn
  aws_region       = var.aws_region
  account_id       = data.aws_caller_identity.current.account_id
}
