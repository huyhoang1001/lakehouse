# data.tf — Day 2 module data sources
# Day 1 outputs arrive as input variables (via root main.tf).
# No terraform_remote_state needed.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
