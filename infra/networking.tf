# networking.tf
# -----------------------------------------------------------------------------
# Network data sources and security groups for RDS and the Glue JDBC connection.
#
# Includes:
#   - data.aws_vpc.default                        — default VPC
#   - data.aws_subnets.default                    — subnets in the default VPC
#   - data.aws_route_table.default_main           — main route table (for S3 endpoint)
#   - aws_security_group.sg_rds                   — attached to the RDS instance
#   - aws_security_group.sg_glue                  — used by the Glue JDBC connection
#   - aws_security_group_rule.rds_ingress_from_glue — TCP 1433 from sg_glue → sg_rds
#   - aws_security_group_rule.sg_glue_self         — self-referencing rule (Glue ENI req.)
#   - aws_security_group_rule.rds_ingress_local    — TCP 1433 from local IP for sqlcmd seed
#   - data.http.my_ip                              — detects local public IP dynamically
#   - aws_vpc_endpoint.s3                         — S3 Gateway endpoint (required by Glue)
#   - aws_db_subnet_group.rds_subnet_group
#   - aws_db_instance.rds
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
# Main route table of the default VPC — needed to attach the S3 endpoint
# ---------------------------------------------------------------------------

data "aws_route_table" "default_main" {
  filter {
    name   = "association.main"
    values = ["true"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# Local public IP — used to open port 1433 for the sqlcmd seed provisioner.
# Detected dynamically so the rule survives IP changes between applies.
# ---------------------------------------------------------------------------

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

# ---------------------------------------------------------------------------
# Security group — RDS SQL Server Express
# ---------------------------------------------------------------------------

resource "aws_security_group" "sg_rds" {
  name        = "${local.project_name}-sg-rds"
  description = "Controls inbound access to the RDS SQL Server Express instance. Allows port 1433 from the Glue connection SG and from the local machine running terraform apply."
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
# Ingress rule — allow local machine to reach RDS on TCP 1433 for sqlcmd seed
# The IP is detected dynamically via checkip.amazonaws.com so it stays
# correct across IP changes without manual intervention.
# ---------------------------------------------------------------------------

resource "aws_security_group_rule" "rds_ingress_local" {
  type              = "ingress"
  from_port         = 1433
  to_port           = 1433
  protocol          = "tcp"
  cidr_blocks       = ["${chomp(data.http.my_ip.response_body)}/32"]
  security_group_id = aws_security_group.sg_rds.id
  description       = "Allow local machine (terraform apply host) to run sqlcmd seed"
}

# ---------------------------------------------------------------------------
# Self-referencing rule on sg_glue — required by Glue for ENI-to-ENI
# communication between the job driver and executor nodes.
# Without this, Glue crawlers and jobs fail with:
#   "At least one security group must open all ingress ports"
# ---------------------------------------------------------------------------

resource "aws_security_group_rule" "sg_glue_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.sg_glue.id
  security_group_id        = aws_security_group.sg_glue.id
  description              = "Self-referencing rule required by Glue for ENI communication"
}

# ---------------------------------------------------------------------------
# VPC S3 Gateway endpoint — required by Glue crawlers and jobs to reach S3
# (scripts, library, temp path, Spark logs) from within the VPC.
# Without this, crawlers fail with:
#   "Could not find S3 endpoint or NAT gateway for subnetId"
# Gateway endpoints are free and do not require a NAT gateway.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.default_main.id]

  tags = merge(var.tags, {
    Name = "${local.project_name}-s3-endpoint"
  })
}

# ---------------------------------------------------------------------------
# DB subnet group
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
# RDS SQL Server Express instance
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
