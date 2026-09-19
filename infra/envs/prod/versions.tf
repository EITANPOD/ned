terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ned"
      ManagedBy = "terraform"
      # ponytail: kept as "aws" (the old root's name) so migrating adds no tag drift.
      Module = "aws"
    }
  }
}
