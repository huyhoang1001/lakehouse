# versions.tf
# -----------------------------------------------------------------------------
# Provider requirements for the Day 3 transform module (Delta Lake + Redshift).
# The root module already constrains the aws provider; this block keeps the
# module independently validatable.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
