# redshift.tf
# -----------------------------------------------------------------------------
# Amazon Redshift warehouse for the Day 3 Redshift load jobs (Req 4).
#
# Everything here is gated by `var.enable_redshift`, so a Delta-only apply
# creates none of it (Req 4.4). The cluster bills hourly — keep
# enable_redshift = false (or `terraform destroy`) when the lab is idle.
#
# Security groups:
#   - sg_redshift_glue — attached to the conRedshift_tickit Glue connection
#     (the job ENIs live here). A self-referencing rule is required by Glue.
#   - sg_redshift      — attached to the cluster; allows 5439 from sg_redshift_glue.
# -----------------------------------------------------------------------------

# --- Security group used by the Glue connection ------------------------------

resource "aws_security_group" "sg_redshift_glue" {
  count = var.enable_redshift ? 1 : 0

  name        = "${local.project_name}-sg-redshift-glue"
  description = "Attached to the conRedshift_tickit Glue connection. Workers in this SG are granted inbound access to Redshift port 5439."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.project_name}-sg-redshift-glue"
  })
}

# Self-referencing rule required by Glue for ENI-to-ENI communication between the
# driver and executor nodes.
resource "aws_security_group_rule" "sg_redshift_glue_self" {
  count = var.enable_redshift ? 1 : 0

  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.sg_redshift_glue[0].id
  security_group_id        = aws_security_group.sg_redshift_glue[0].id
  description              = "Self-referencing rule required by Glue for ENI communication"
}

# --- Security group attached to the cluster ----------------------------------

resource "aws_security_group" "sg_redshift" {
  count = var.enable_redshift ? 1 : 0

  name        = "${local.project_name}-sg-redshift"
  description = "Controls inbound access to the Redshift cluster. Allows port 5439 from the Glue connection SG."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.project_name}-sg-redshift"
  })
}

# Ingress — allow Glue workers to reach Redshift on TCP 5439 (Req 4.2).
resource "aws_security_group_rule" "redshift_ingress_from_glue" {
  count = var.enable_redshift ? 1 : 0

  type                     = "ingress"
  from_port                = local.redshift_port
  to_port                  = local.redshift_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_redshift_glue[0].id
  security_group_id        = aws_security_group.sg_redshift[0].id
  description              = "Allow Glue JDBC workers to reach Redshift on port 5439"
}

# --- Subnet group over the default VPC subnets (Req 4.2) ---------------------

resource "aws_redshift_subnet_group" "this" {
  count = var.enable_redshift ? 1 : 0

  name        = "${replace(lower(local.project_name), "_", "-")}-redshift-subnet-group"
  description = "Subnet group for the NT_Accelerate Redshift cluster (default VPC subnets)"
  subnet_ids  = data.aws_subnets.default.ids

  tags = merge(var.tags, {
    Name = "${replace(lower(local.project_name), "_", "-")}-redshift-subnet-group"
  })
}

# --- Cluster (Req 4.1) -------------------------------------------------------

resource "aws_redshift_cluster" "this" {
  count = var.enable_redshift ? 1 : 0

  cluster_identifier = local.redshift_cluster_id # "nt-accelerate-redshift"
  database_name      = var.redshift_database_name
  master_username    = var.redshift_master_username
  master_password    = var.redshift_master_password

  node_type       = var.redshift_node_type
  number_of_nodes = var.redshift_number_of_nodes

  cluster_subnet_group_name = aws_redshift_subnet_group.this[0].name
  vpc_security_group_ids    = [aws_security_group.sg_redshift[0].id]
  publicly_accessible       = var.redshift_publicly_accessible

  # Keeps teardown clean — no final snapshot to retain (Req 4.1 / 13.3).
  skip_final_snapshot = true

  tags = merge(var.tags, {
    Name = local.redshift_cluster_id
  })
}
