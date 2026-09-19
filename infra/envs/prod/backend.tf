# Partial S3 backend: bucket and region come from -backend-config in CI.
# Key stays "aws/terraform.tfstate" (the pre-restructure infra/aws key): the CI
# roles' S3 grants and the plan-stash keys are scoped to it.
terraform {
  backend "s3" {
    key          = "aws/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
