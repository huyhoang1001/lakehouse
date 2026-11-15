# versions.tf
# -----------------------------------------------------------------------------
# Terraform and provider version constraints for the NT Accelerate Day 1 stack.
# Only version/provider pinning lives here; resources are defined in later task
# files (S3, IAM, networking, RDS, Secrets, DynamoDB, Glue).
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Primary provider for every AWS resource in the stack.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Used later (task 2.4) to zip Genericlib.py into Genericlib.zip for the
    # Glue library upload.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }

    # Used later for local-exec RDS seeding (task 6.1) and bucket emptying
    # before destroy (task 11.1).
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
