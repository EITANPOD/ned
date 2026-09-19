# Partial config: bucket/region passed via -backend-config (see README runbook).
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
