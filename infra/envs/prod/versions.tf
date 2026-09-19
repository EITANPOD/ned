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
      # Kept as "aws" (the old root's name) so default tags don't drift during the migration.
      Module = "aws"
    }
  }
}
