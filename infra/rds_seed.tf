# rds_seed.tf
# -----------------------------------------------------------------------------
# Seeds the RDS SQL Server Express instance with the Tickit database schema
# and sample data using the provided tickit_script.sql.
#
# Prerequisites:
#   sqlcmd must be installed on the machine running `terraform apply`.
#   macOS: brew install sqlcmd
#   Linux: install via Microsoft mssql-tools package
#
# Tasks 6.1 and 6.2:
#   - null_resource with local-exec to run sqlcmd (task 6.1)
#   - triggers on filesha256() for change detection (task 6.2)
#   - idempotency guard: creates the tickit DB if absent, then checks
#     sys.tables row count inside tickit before running the script (task 6.2)
#
# Note: tickit_script.sql begins with USE [tickit], so the tickit database
# must exist before the script runs. This provisioner creates it if absent.
# The sg_rds security group allows TCP 1433 from the local machine's public
# IP (detected dynamically in networking.tf) so sqlcmd can reach RDS.
# -----------------------------------------------------------------------------

resource "null_resource" "db_seed" {
  triggers = {
    script_hash = filesha256("${path.module}/../instruction/day1/tickit_db 2/tickit_db/tickit_script.sql")
  }

  provisioner "local-exec" {
    command = <<-EOT
      RDS="${aws_db_instance.rds.address},1433"
      USER="${var.db_username}"
      PASS="${var.db_password}"
      SCRIPT="${path.module}/../instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"

      # Step 1: Create the tickit database if it does not exist.
      sqlcmd -S "$RDS" -U "$USER" -P "$PASS" \
        -Q "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'tickit') CREATE DATABASE tickit;" 2>&1

      # Step 2: Count the 7 expected Tickit tables inside the tickit database.
      TABLE_COUNT=$(sqlcmd -S "$RDS" -U "$USER" -P "$PASS" -d tickit \
        -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name IN ('category','date','event','listing','sales','users','venue') AND OBJECT_SCHEMA_NAME(object_id) = 'dbo';" \
        -h -1 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' | head -1)

      echo "Tickit table count: $TABLE_COUNT"

      if [ "$TABLE_COUNT" = "7" ]; then
        echo "All 7 Tickit tables already exist — skipping seed."
      else
        echo "Seeding RDS with tickit_script.sql..."
        sqlcmd -S "$RDS" -U "$USER" -P "$PASS" -d tickit -i "$SCRIPT"
        echo "Seed complete."
      fi
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    aws_db_instance.rds,
    aws_security_group_rule.rds_ingress_local,
  ]
}
