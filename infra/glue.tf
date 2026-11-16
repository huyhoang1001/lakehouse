# glue.tf
# -----------------------------------------------------------------------------
# Glue Data Catalog, JDBC connection, and crawler for the NT Accelerate stack.
#
# Resources in this file (by task):
#   - Task 8.1  aws_glue_catalog_database "tickit"      ← this task
#   - Task 8.2  aws_glue_connection       "conRDS_tickit"  (added in 8.2)
#   - Task 8.3  aws_glue_crawler          "NT_Accelerate_cwl_RDSTickit"  (added in 8.3)
# -----------------------------------------------------------------------------

# Task 8.1 — Glue Data Catalog database (refs Req 7)
# aws_glue_catalog_database does not support a tags argument; tags block omitted.
resource "aws_glue_catalog_database" "tickit" {
  name        = local.glue_database_name # "tickit"
  description = "Glue Data Catalog database for the TICKIT demo schema extracted from RDS SQL Server. Populated by the NT_Accelerate_cwl_RDSTickit crawler."
}

# ---------------------------------------------------------------------------
# Task 8.2 — Data source: look up the first default subnet to get its AZ
# ---------------------------------------------------------------------------

data "aws_subnet" "first" {
  id = tolist(data.aws_subnets.default.ids)[0]
}

# Task 8.2 — Glue JDBC connection (refs Req 7)
resource "aws_glue_connection" "conRDS_tickit" {
  name            = local.glue_connection_name # "conRDS_tickit"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:sqlserver://${aws_db_instance.rds.address}:1433;databaseName=tickit"
    USERNAME            = var.db_username
    PASSWORD            = var.db_password
  }

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.first.availability_zone
    security_group_id_list = [aws_security_group.sg_glue.id]
    subnet_id              = data.aws_subnet.first.id
  }
}

# Task 8.3 — Glue crawler (refs Req 7)
resource "aws_glue_crawler" "rds_tickit" {
  name          = local.crawler_name         # "NT_Accelerate_cwl_RDSTickit"
  role          = aws_iam_role.glue.arn
  database_name = local.glue_database_name  # "tickit"

  jdbc_target {
    connection_name = aws_glue_connection.conRDS_tickit.name
    path            = "tickit/%"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = merge(var.tags, {
    Name = local.crawler_name
  })
}
