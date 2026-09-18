mock_provider "aws" {}

variables {
  github_repo       = "EITANPOD/ned"
  aws_region        = "us-east-1"
  state_bucket_name = "ned-tfstate-test"
}

run "bucket_is_hardened" {
  command = apply

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "state bucket must have versioning enabled"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "state bucket must block public access"
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "state bucket must be SSE encrypted"
  }
}

run "ci_role_trusts_only_this_repo" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_role.ci.assume_role_policy, "repo:EITANPOD/ned:*")
    error_message = "CI role trust must be scoped to the repo"
  }
  assert {
    condition     = strcontains(aws_iam_role.ci.assume_role_policy, "sts.amazonaws.com")
    error_message = "CI role trust must require aud=sts.amazonaws.com"
  }
}

run "ci_role_has_no_wildcard_admin" {
  command = apply

  assert {
    condition     = !strcontains(aws_iam_role_policy.ci.policy, "\"Action\":\"*\"") && !strcontains(aws_iam_role_policy.ci.policy, "\"Action\": \"*\"")
    error_message = "CI role policy must not grant Action:*"
  }
}
