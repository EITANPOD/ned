terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }

  # Partial config: bucket/region passed via -backend-config in CI.
  # First bootstrap run uses `terraform init -backend=false` (local state),
  # then migrates into this backend.
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ned"
      ManagedBy = "terraform"
      Module    = "bootstrap"
    }
  }
}
