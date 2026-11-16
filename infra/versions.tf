# versions.tf
# -----------------------------------------------------------------------------
# Terraform and provider version constraints for the NT Accelerate Day 1 stack.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    # Used to detect the local machine's public IP dynamically for the
    # sg_rds ingress rule that allows sqlcmd to reach RDS during seeding.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
