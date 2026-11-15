# providers.tf
# -----------------------------------------------------------------------------
# AWS provider configuration.
#
# Credentials are resolved through the AWS default credential chain — environment
# variables (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN),
# the shared credentials file (~/.aws/credentials), or an IAM role. No static
# access keys are stored in this code.
#
# default_tags applies var.tags to every taggable resource so the stack inherits
# a consistent Project / ManagedBy labeling without per-resource repetition.
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
