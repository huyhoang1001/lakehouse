# data.tf — Day 3 module data sources
# Day 1 and Day 2 outputs arrive as input variables (via root main.tf).
# The default VPC lookups are used for the Redshift subnet group and the
# Glue JDBC connection's physical connection requirements.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_vpc" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# First default subnet — supplies the availability zone for the Glue JDBC
# connection's physical connection requirements.
data "aws_subnet" "first" {
  id = tolist(data.aws_subnets.default.ids)[0]
}
