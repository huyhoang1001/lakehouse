# rds_seed.tf
# -----------------------------------------------------------------------------
# Seeds the RDS SQL Server Express instance with the Tickit database schema
# and sample data using scripts/batch_seed.py.
#
# batch_seed.py rewrites the ~424k single-row INSERTs before loading:
#   1. 200 rows per INSERT ... VALUES (...), (...), so SQL Server parses
#      ~2k statements instead of ~424k (the previous single-row load did
#      not reliably finish in 5 minutes on db.t3.micro).
#   2. COMMIT every 2000 rows, one sqlcmd process per table.
#   3. Resume is per table: matching COUNT(*) skips the table; a partial
#      heap is truncated and reloaded (there is no key to resume by row).
#   4. The process exits non-zero if a table count does not match the script.
#
# Prerequisites:
#   - sqlcmd must be installed (brew install sqlcmd)
#   - The tickit_script.sql must be a real file, not a Git LFS pointer.
#     Run: git lfs pull --include="instruction/day1/tickit_db 2/..."
#
# The sg_rds security group allows TCP 1433 from the local machine's public
# IP (detected dynamically via data.http.my_ip in networking.tf), so sqlcmd
# can reach RDS during terraform apply without manual SG edits.
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
      SEED_PY="${path.module}/scripts/batch_seed.py"

      # Verify sqlcmd is available
      if ! command -v sqlcmd &>/dev/null; then
        echo "ERROR: sqlcmd not found. Install with: brew install sqlcmd"
        exit 1
      fi

      # Verify the SQL script is real content, not a Git LFS pointer
      if head -1 "$SCRIPT" | grep -q "^version https://git-lfs"; then
        echo "ERROR: tickit_script.sql is a Git LFS pointer, not the real file."
        echo "Run: git lfs pull --include=\"instruction/day1/tickit_db 2/tickit_db/tickit_script.sql\""
        exit 1
      fi

      # Create the tickit database if it does not exist
      sqlcmd -S "$RDS" -U "$USER" -P "$PASS" \
        -Q "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name='tickit') CREATE DATABASE tickit;" 2>&1

      # Seed using the batch script (transaction-batched, resume-aware)
      python3 "$SEED_PY" \
        --server "$RDS" \
        --user   "$USER" \
        --password "$PASS" \
        --script "$SCRIPT"
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    aws_db_instance.rds,
    aws_security_group_rule.rds_ingress_local,
  ]
}
