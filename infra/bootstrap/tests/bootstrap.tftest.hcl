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

run "ci_role_cannot_modify_itself" {
  command = apply

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : s if s.Effect == "Deny" && s.Sid == "DenySelfModifyAndBoundaryRemoval"]) == 1
    error_message = "CI role policy must contain the self-modify Deny statement"
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : s if s.Effect == "Deny" && s.Sid == "DenyBoundaryRemoval"]) == 1
    error_message = "CI role policy must deny removing permissions boundaries"
  }
}

run "ci_role_requires_boundary_on_create" {
  command = apply

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : s if s.Sid == "NedIamCreateWithBoundary" && try(s.Condition.StringEquals["iam:PermissionsBoundary"], "") != ""]) == 1
    error_message = "iam:CreateUser/CreateRole must be conditioned on iam:PermissionsBoundary"
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : s if s.Sid == "NedIamAttachScopedPolicies" && try(s.Condition.ArnLike["iam:PolicyARN"], "") != ""]) == 1
    error_message = "AttachUserPolicy must be conditioned on iam:PolicyARN"
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : s if s.Sid == "PassRoleToBedrockOnly" && try(s.Condition.StringEquals["iam:PassedToService"], "") == "bedrock.amazonaws.com"]) == 1
    error_message = "PassRole must be limited to bedrock.amazonaws.com"
  }
}

run "boundary_policy_named" {
  command = apply

  assert {
    condition     = aws_iam_policy.boundary.name == "ned-permissions-boundary"
    error_message = "boundary policy must be ned-permissions-boundary"
  }
}
