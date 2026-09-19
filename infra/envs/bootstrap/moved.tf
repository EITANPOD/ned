# In-place migration from infra/bootstrap (flat resources) to the official modules. Remove these
# blocks once the migration has been applied everywhere.

moved {
  from = aws_s3_bucket.state
  to   = module.state_bucket.aws_s3_bucket.this[0]
}

moved {
  from = aws_s3_bucket_versioning.state
  to   = module.state_bucket.aws_s3_bucket_versioning.this[0]
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.state
  to   = module.state_bucket.aws_s3_bucket_server_side_encryption_configuration.this[0]
}

moved {
  from = aws_s3_bucket_public_access_block.state
  to   = module.state_bucket.aws_s3_bucket_public_access_block.this[0]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.state
  to   = module.state_bucket.aws_s3_bucket_lifecycle_configuration.this[0]
}

moved {
  from = aws_iam_openid_connect_provider.github
  to   = module.github_ci_role.module.oidc_provider.aws_iam_openid_connect_provider.this[0]
}

moved {
  from = aws_iam_role.ci
  to   = module.github_ci_role.module.role.aws_iam_role.this[0]
}

moved {
  from = aws_iam_role_policy.ci
  to   = module.github_ci_role.module.role.aws_iam_role_policy.inline[0]
}

moved {
  from = aws_iam_policy.user_boundary
  to   = module.github_ci_role.aws_iam_policy.user_boundary
}

moved {
  from = aws_iam_policy.role_boundary
  to   = module.github_ci_role.aws_iam_policy.role_boundary
}
