terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }

  backend "s3" {
    key          = "aws/terraform.tfstate"
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
      Module    = "aws"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Created by infra/bootstrap; the CI role may only create principals carrying them.
  # Split by principal type: users get Bedrock, roles get log writes only.
  user_boundary_arn = "arn:aws:iam::${local.account_id}:policy/ned-user-boundary"
  role_boundary_arn = "arn:aws:iam::${local.account_id}:policy/ned-role-boundary"
}
