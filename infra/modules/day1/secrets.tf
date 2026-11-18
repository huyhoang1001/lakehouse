# secrets.tf
# -----------------------------------------------------------------------------
# Secrets Manager secret for the RDS JDBC connection credentials.
#
# Includes:
#   - aws_secretsmanager_secret "rds_secret"   (task 5.1)
#
# The secret version (task 5.2) and its ARN wired into the Glue role policy
# (task 5.3) are added in subsequent tasks.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "rds_secret" {
  name        = local.secret_name # "SQLSource_Database_Connection_Info"
  description = "RDS SQL Server Express JDBC credentials (username, password, JDBC URL, driver class) used by NT Accelerate Glue extraction jobs."

  # Set to 0 so the secret can be immediately deleted during sandbox teardown
  # without waiting for a 7–30 day recovery window.
  recovery_window_in_days = 0

  tags = merge(var.tags, {
    Name = local.secret_name
  })
}

# ---------------------------------------------------------------------------
# Secret version — stores the JDBC credentials as a JSON object (task 5.2)
# Genericlib.py reads the four keys: db_username, db_password, db_url,
# driver_name.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret_version" "rds_secret_version" {
  secret_id = aws_secretsmanager_secret.rds_secret.id
  secret_string = jsonencode({
    db_username = var.db_username
    db_password = var.db_password
    db_url      = "jdbc:sqlserver://${aws_db_instance.rds.address}:1433;databaseName=tickit"
    driver_name = "com.microsoft.sqlserver.jdbc.SQLServerDriver"
  })
}
