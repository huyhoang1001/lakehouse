# networking.tf
# -----------------------------------------------------------------------------
# Network data sources and security groups for RDS and the Glue JDBC connection.
#
# Includes:
#   - data.aws_vpc.default          — default VPC (task 4.1)
#   - data.aws_subnets.default      — subnets in the default VPC (task 4.1)
#   - aws_security_group.sg_rds     — attached to the RDS instance (task 4.1)
#   - aws_security_group.sg_glue    — used by the Glue JDBC connection (task 4.1)
#
# Ingress rule allowing TCP 1433 from sg_glue into sg_rds (aws_security_group_rule.rds_ingress_from_glue).
# The aws_db_subnet_group and aws_db_instance are added in tasks 4.3–4.4.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Default VPC
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

# ---------------------------------------------------------------------------
# Default subnets (all AZs in the default VPC)
# ---------------------------------------------------------------------------

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# Security group — RDS SQL Server Express
# Attached to the RDS instance; ingress from sg_glue defined below as
# aws_security_group_rule.rds_ingress_from_glue (task 4.2).
# ---------------------------------------------------------------------------

resource "aws_security_group" "sg_rds" {
  name        = "${local.project_name}-sg-rds"
  description = "Controls inbound access to the RDS SQL Server Express instance. Allows port 1433 from the Glue connection SG."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.project_name}-sg-rds"
  })
}

# ---------------------------------------------------------------------------
# Security group — Glue JDBC connection
# Referenced as the source in the sg_rds ingress rule (task 4.2) so Glue
# workers can reach RDS on port 1433.
# ---------------------------------------------------------------------------

resource "aws_security_group" "sg_glue" {
  name        = "${local.project_name}-sg-glue"
  description = "Attached to the Glue JDBC connection. Workers in this SG are granted inbound access to RDS port 1433."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.project_name}-sg-glue"
  })
}

# ---------------------------------------------------------------------------
# Ingress rule — allow Glue workers to reach RDS on TCP 1433
# Defined as a standalone aws_security_group_rule to avoid dependency cycles
# when both SGs reference each other.
# ---------------------------------------------------------------------------

resource "aws_security_group_rule" "rds_ingress_from_glue" {
  type                     = "ingress"
  from_port                = 1433
  to_port                  = 1433
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_glue.id
  security_group_id        = aws_security_group.sg_rds.id
  description              = "Allow Glue JDBC workers to reach SQL Server on port 1433"
}

# ---------------------------------------------------------------------------
# DB subnet group — required by aws_db_instance (task 4.4)
# Uses all subnets in the default VPC so RDS can be placed in any AZ.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "${lower(local.project_name)}-rds-subnet-group"
  description = "Subnet group for the NT_Accelerate RDS SQL Server Express instance (default VPC subnets)"
  subnet_ids  = data.aws_subnets.default.ids

  tags = merge(var.tags, {
    Name = "${local.project_name}-rds-subnet-group"
  })
}

# ---------------------------------------------------------------------------
# RDS SQL Server Express instance (task 4.4)
# ---------------------------------------------------------------------------

resource "aws_db_instance" "rds" {
  identifier        = "${replace(lower(local.project_name), "_", "-")}-sqlserver"
  engine            = "sqlserver-ex"
  engine_version    = null # AWS picks the latest Express edition
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp2"
  license_model     = "license-included"

  username = var.db_username
  password = var.db_password

  # SQL Server Express does not support the db_name parameter (fixed instance)

  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.sg_rds.id]
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name

  skip_final_snapshot = true

  tags = merge(var.tags, {
    Name = "${local.project_name}-sqlserver-express"
  })
}
