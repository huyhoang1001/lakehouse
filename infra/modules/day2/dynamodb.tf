# dynamodb.tf
# -----------------------------------------------------------------------------
# Task 4 — DynamoDB tables and seed items for the Day 2 control plane.
#
#   NT_Accelerate_MASTER_JOB_CONFIG  (new)  — run type / batch id / last status
#   NT_Accelerate_Mail_Config        (new)  — SES sender + receivers
#   NT_Accelerate_JOB_CONFIG         (Day 1) — extended with the Day 2 columns
#
# The four Day 1 tables are NOT re-created here (Req 5.5); only the JOB_CONFIG
# rows are rewritten as a superset so NT_Accelerate_Is_Allow_Running can read
# every field it needs without a KeyError (Req 6).
# -----------------------------------------------------------------------------

locals {
  # Name of the Day 1 JOB_CONFIG table, derived from its ARN rather than
  # hardcoded, so the reference stays a module input (Req 1.2).
  job_config_table_name = element(split(":table/", var.dynamodb_table_arns["job_config"]), 1)

  # The seven Day 1 extraction jobs. Mirrors the Day 1 seed rows; Day 2 owns the
  # same primary keys and rewrites each item with the full superset of columns.
  job_config_ext_items = {
    "1" = { job_name = "jb_Stg_Extract_Category", src_table = "tickit_dbo_category", tar_table = "category", incremental = "False" }
    "2" = { job_name = "jb_Stg_Extract_Date", src_table = "tickit_dbo_date", tar_table = "date", incremental = "False" }
    "3" = { job_name = "jb_Stg_Extract_Event", src_table = "tickit_dbo_event", tar_table = "event", incremental = "False" }
    "4" = { job_name = "jb_Stg_Extract_Listing", src_table = "tickit_dbo_listing", tar_table = "listing", incremental = "False" }
    "5" = { job_name = "jb_Stg_Extract_Users", src_table = "tickit_dbo_users", tar_table = "users", incremental = "False" }
    "6" = { job_name = "jb_Stg_Extract_Venue", src_table = "tickit_dbo_venue", tar_table = "venue", incremental = "False" }
    "7" = { job_name = "jb_Stg_Extract_Sales", src_table = "tickit_dbo_sales", tar_table = "sales", incremental = "True" }
  }
}

# Task 4.1 — MASTER_JOB_CONFIG (Req 5.1)
resource "aws_dynamodb_table" "master_job_config" {
  name         = local.ddb_master_job_config # "NT_Accelerate_MASTER_JOB_CONFIG"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "ID"

  attribute {
    name = "ID"
    type = "N"
  }

  tags = merge(var.tags, {
    Name = local.ddb_master_job_config
  })
}

# Task 4.2 — seed the Staging Master row (ID=1) (Req 5.2)
resource "aws_dynamodb_table_item" "master_job_config_seed" {
  table_name = aws_dynamodb_table.master_job_config.name
  hash_key   = aws_dynamodb_table.master_job_config.hash_key

  item = jsonencode({
    "ID"              = { "N" = "1" }
    "RUN_TYPE"        = { "S" = "NEW" }
    "RERUN_DATE"      = { "S" = "2024-01-01" }
    "BATCH_ID"        = { "N" = "0" }
    "LAST_RUN_DATE"   = { "S" = "2024-01-01" }
    "LAST_RUN_STATUS" = { "S" = "NEW" }
  })
}

# Task 4.3 — Mail_Config (Req 5.3)
# NOTE ON THE KEY TYPE: the design document labels this key `N`, but the lab
# artifacts require a STRING key:
#   - the provided sample item is {"ID": {"S": "1"}}, and
#   - NT_Accelerate_Send_Mail scans with Key('ID').eq(str("1")) — a string.
# An N-typed key would never match that scan, so the Lambda could never send
# mail. The key is therefore declared as S to match the Lambda and the sample
# data. (MASTER_JOB_CONFIG keeps an N key because Read_Run_Type passes the
# numeric p_masterjob_id straight into Key('ID').eq(...).)
resource "aws_dynamodb_table" "mail_config" {
  name         = local.ddb_mail_config # "NT_Accelerate_Mail_Config"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "ID"

  attribute {
    name = "ID"
    type = "S"
  }

  tags = merge(var.tags, {
    Name = local.ddb_mail_config
  })
}

# Task 4.4 — seed Mail_Config (Req 5.4)
# RECEIVER is a DynamoDB List (L) of strings: Send_Mail passes it straight to
# ses:GetIdentityVerificationAttributes(Identities=...) and then mutates it with
# .remove(), which requires a list, not a string set.
resource "aws_dynamodb_table_item" "mail_config_seed" {
  table_name = aws_dynamodb_table.mail_config.name
  hash_key   = aws_dynamodb_table.mail_config.hash_key

  item = jsonencode({
    "ID"       = { "S" = "1" }
    "SENDER"   = { "S" = var.ses_sender_email }
    "RECEIVER" = { "L" = [for email in var.ses_receiver_emails : { "S" = email }] }
  })
}

# Task 4.5 — rewrite the Day 1 JOB_CONFIG items with the Day 2 columns (Req 6)
# -----------------------------------------------------------------------------
# Each item is a superset that still carries every Day 1 column (Req 6.3) plus
# the Day 2 columns. The attribute names the orchestration reads come from the
# original lab table definition (INCREMENTAL_LOAD / REGION_NAME / SRC_DBNAME /
# SRC_TBLNAME / TRG_DBNAME / TRG_TBLNAME) — NT_Accelerate_Is_Allow_Running reads
# those names directly, so they are the ones that must exist for the staging
# layer to resolve job parameters without a KeyError (Req 6 user story).
#
# `lifecycle { ignore_changes = [] }` (Req 6.4) records that later runtime
# updates to these items are performed by the Lambdas, not reconciled by
# Terraform.
resource "aws_dynamodb_table_item" "job_config_ext" {
  for_each = local.job_config_ext_items

  table_name = local.job_config_table_name
  hash_key   = "ID"

  item = jsonencode({
    # --- Day 1 columns, preserved unchanged (Req 6.3) ---
    "ID"                    = { "N" = each.key }
    "JOB_NAME"              = { "S" = each.value.job_name }
    "p_src_tableName"       = { "S" = each.value.src_table }
    "p_tar_tablename"       = { "S" = each.value.tar_table }
    "p_is_incremental_load" = { "S" = each.value.incremental }
    "p_region"              = { "S" = var.aws_region }
    "p_src_databaseName"    = { "S" = "tickit" }
    "p_tar_databaseName"    = { "S" = "s3://${var.bucket_name}/lake/bronze/tickit/" }
    "p_catalog_conn"        = { "S" = "conRDS_tickit" }

    # --- Day 2 columns (Req 6.1) ---
    "LAYER"              = { "S" = "STAGING" }
    "MULTIPLE_RUN"       = { "S" = "FALSE" }
    "CATALOG_CON"        = { "S" = "conRDS_tickit" }
    "LAKEHOUSE_LOCATION" = { "S" = "" }
    "POSTSCRIPT"         = { "S" = "" }
    "PRESCRIPT"          = { "S" = "" }
    "TEMP_FOLDER"        = { "S" = "" }

    # --- Attribute names read by NT_Accelerate_Is_Allow_Running (Req 6 user story) ---
    "INCREMENTAL_LOAD" = { "S" = each.value.incremental }
    "REGION_NAME"      = { "S" = var.aws_region }
    "SRC_DBNAME"       = { "S" = "tickit" }
    "SRC_TBLNAME"      = { "S" = each.value.src_table }
    "TRG_DBNAME"       = { "S" = "s3://${var.bucket_name}/lake/bronze/tickit/" }
    "TRG_TBLNAME"      = { "S" = each.value.tar_table }
  })

  lifecycle {
    ignore_changes = []
  }
}
