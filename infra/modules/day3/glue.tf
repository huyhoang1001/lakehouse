# glue.tf
# -----------------------------------------------------------------------------
# Glue JDBC connection to the Redshift warehouse (Req 6.1).
#
# The Redshift load jobs attach this connection so their ENIs are created in the
# default VPC (via sg_redshift_glue) and can reach the cluster on port 5439.
# The connection carries the JDBC URL + credentials; the script passes the
# connection name as --p_catalog_con.
# -----------------------------------------------------------------------------

resource "aws_glue_connection" "conRedshift_tickit" {
  count = var.enable_redshift ? 1 : 0

  name            = local.redshift_connection_name # "conRedshift_tickit"
  connection_type = "JDBC"

  connection_properties = {
    # `endpoint` already includes the port, e.g. "host:5439".
    JDBC_CONNECTION_URL = "jdbc:redshift://${aws_redshift_cluster.this[0].endpoint}/${var.redshift_database_name}"
    USERNAME            = var.redshift_master_username
    PASSWORD            = var.redshift_master_password
  }

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.first.availability_zone
    security_group_id_list = [aws_security_group.sg_redshift_glue[0].id]
    subnet_id              = data.aws_subnet.first.id
  }
}
