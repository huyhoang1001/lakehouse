# rds_seed.tf
# -----------------------------------------------------------------------------
# Seeds the RDS SQL Server Express instance with the Tickit database schema
# and sample data using the provided tickit_script.sql.
#
# Prerequisites:
#   sqlcmd (SQL Server command-line tools) must be installed on the machine
#   running `terraform apply`. On macOS: `brew install sqlcmd`.
#   On Linux: install via Microsoft's mssql-tools package.
#
# Tasks 6.1 and 6.2:
#   - null_resource with local-exec to run sqlcmd (task 6.1)
#   - triggers on filesha256() for change detection (task 6.2)
#   - sys.tables existence check for idempotency (task 6.2)
# -----------------------------------------------------------------------------

resource "null_resource" "db_seed" {
  triggers = {
    script_hash = filesha256("${path.module}/../instruction/day1/tickit_db 2/tickit_db/tickit_script.sql")
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Check if the tickit tables already exist; skip seeding if they do.
      # -h -1 suppresses column headers so the output is a bare integer.
      TABLE_COUNT=$(sqlcmd -S "${aws_db_instance.rds.address},1433" \
        -U "${var.db_username}" \
        -P "${var.db_password}" \
        -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name IN ('category','date','event','listing','sales','users','venue');" \
        -h -1 2>/dev/null | tr -d '[:space:]')
      if [ "$TABLE_COUNT" = "7" ]; then
        echo "Tickit tables already exist, skipping seed."
      else
        sqlcmd -S "${aws_db_instance.rds.address},1433" \
          -U "${var.db_username}" \
          -P "${var.db_password}" \
          -i "${path.module}/../instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"
      fi
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [aws_db_instance.rds]
}
