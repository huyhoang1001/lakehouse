# providers.tf
# -----------------------------------------------------------------------------
# AWS provider for the entire stack. Credentials are resolved through the
# default AWS credential chain. default_tags applies var.tags to every
# taggable resource across both modules.
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
