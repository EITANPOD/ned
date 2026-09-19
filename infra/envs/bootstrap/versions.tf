terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ned"
      ManagedBy = "terraform"
      # Kept as "bootstrap" (not the new path) so the migration does not retag every resource.
      Module = "bootstrap"
    }
  }
}
