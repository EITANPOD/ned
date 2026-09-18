terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }

  # Partial config: bucket/region passed via -backend-config.
  # One-time local bootstrap: apply with a temporary `zz_local_override.tf`
  # (backend "local"), delete it, then `terraform init -migrate-state`.
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
