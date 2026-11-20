# secrets.tf
# -----------------------------------------------------------------------------
# Secrets Manager secret holding the Redshift connection info (Req 6.2, 6.4).
#
# Gated by enable_redshift. The Glue role is granted secretsmanager:GetSecretValue
# on this secret by the Day 3 inline policy (see iam.tf / Req 9.2).
# The password is never written anywhere except this secret version and the
# cluster's own master_password input.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "redshift_secret" {
  count = var.enable_redshift ? 1 : 0

  name        = local.redshift_secret_name # "Redshift_Database_Connection_Info"
  description = "Amazon Redshift JDBC credentials (username, password, JDBC URL, driver class) used by the NT Accelerate Redshift load jobs."

  # Set to 0 so the secret can be deleted immediately during sandbox teardown.
  recovery_window_in_days = 0

  tags = merge(var.tags, {
    Name = local.redshift_secret_name
  })
}

resource "aws_secretsmanager_secret_version" "redshift_secret_version" {
  count = var.enable_redshift ? 1 : 0

  secret_id = aws_secretsmanager_secret.redshift_secret[0].id
  secret_string = jsonencode({
    username = var.redshift_master_username
    password = var.redshift_master_password
    url      = "jdbc:redshift://${aws_redshift_cluster.this[0].endpoint}/${var.redshift_database_name}"
    driver   = "com.amazon.redshift.jdbc42.Driver"
  })
}
