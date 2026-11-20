# dynamodb.tf
# -----------------------------------------------------------------------------
# Day 3 control-table seed rows.
#
#   - NT_Accelerate_JOB_CONFIG        : +12 rows (IDs 8–19), one per Glue job
#   - NT_Accelerate_MASTER_JOB_CONFIG : +row ID=2 (LakeHouse), ID=3 (RedshiftDW)
#
# Neither table is created here — JOB_CONFIG is owned by Day 1 and
# MASTER_JOB_CONFIG by Day 2; Day 3 only adds rows (Req 7.7, 8.3).
#
# Each JOB_CONFIG row carries the full superset of columns that
# NT_Accelerate_Is_Allow_Running projects and reads:
#   JOB_NAME, LAYER, MULTIPLE_RUN, REGION_NAME, SRC_DBNAME, SRC_TBLNAME,
#   TRG_DBNAME, TRG_TBLNAME, INCREMENTAL_LOAD, CATALOG_CON, LAKEHOUSE_LOCATION,
#   PRESCRIPT, POSTSCRIPT, TEMP_FOLDER.
# The LAYER value drives which of those columns the Lambda actually uses:
#   LAKEHOUSE -> LAKEHOUSE_LOCATION ; DW -> CATALOG_CON/PRESCRIPT/POSTSCRIPT/TEMP_FOLDER.
# -----------------------------------------------------------------------------

# --- Delta rows (LAYER = LAKEHOUSE), IDs 8–13 (Req 7.1, 7.3) -----------------

resource "aws_dynamodb_table_item" "job_config_delta" {
  for_each = local.delta_jobs

  table_name = var.job_config_table_name
  hash_key   = "ID"

  item = jsonencode({
    "ID"                 = { "N" = each.value.id }
    "JOB_NAME"           = { "S" = "jb_DW_Delta_Load_${each.key}" }
    "LAYER"              = { "S" = "LAKEHOUSE" }
    "MULTIPLE_RUN"       = { "S" = "FALSE" }
    "REGION_NAME"        = { "S" = var.aws_region }
    "SRC_DBNAME"         = { "S" = var.glue_database_name }
    "SRC_TBLNAME"        = { "S" = each.value.src_table }
    "TRG_DBNAME"         = { "S" = local.lakehouse_location }
    "TRG_TBLNAME"        = { "S" = each.key }
    "INCREMENTAL_LOAD"   = { "S" = "False" }
    "CATALOG_CON"        = { "S" = "" }
    "LAKEHOUSE_LOCATION" = { "S" = local.lakehouse_location }
    "PRESCRIPT"          = { "S" = "" }
    "POSTSCRIPT"         = { "S" = "" }
    "TEMP_FOLDER"        = { "S" = "" }
  })
}

# --- Redshift rows (LAYER = DW), IDs 14–19 (Req 7.1, 7.4) --------------------
# Gated by enable_redshift: no cluster means no job and no config row.

resource "aws_dynamodb_table_item" "job_config_redshift" {
  for_each = var.enable_redshift ? local.redshift_jobs : {}

  table_name = var.job_config_table_name
  hash_key   = "ID"

  item = jsonencode({
    "ID"                 = { "N" = each.value.id }
    "JOB_NAME"           = { "S" = "jb_DW_Redshift_Load_${each.key}" }
    "LAYER"              = { "S" = "DW" }
    "MULTIPLE_RUN"       = { "S" = "FALSE" }
    "REGION_NAME"        = { "S" = var.aws_region }
    "SRC_DBNAME"         = { "S" = var.glue_database_name }
    "SRC_TBLNAME"        = { "S" = each.value.src_table }
    "TRG_DBNAME"         = { "S" = var.redshift_database_name }
    "TRG_TBLNAME"        = { "S" = each.value.trg_table }
    "INCREMENTAL_LOAD"   = { "S" = "False" }
    "CATALOG_CON"        = { "S" = local.redshift_connection_name }
    "LAKEHOUSE_LOCATION" = { "S" = "" }
    "PRESCRIPT"          = { "S" = "drop table if exists ${each.value.trg_table}" }
    "POSTSCRIPT"         = { "S" = "analyze ${each.value.trg_table}" }
    "TEMP_FOLDER"        = { "S" = local.temporary_location }
  })
}

# --- MASTER_JOB_CONFIG rows ID=2 and ID=3 (Req 8.1, 8.2) ---------------------
# Same seed shape as the Day 2 row ID=1. The Day 2 row is not touched.

locals {
  master_job_config_seed = {
    "2" = "NT_Accelerate_LakeHouse_Master_Job"
    "3" = "NT_Accelerate_RedshiftDW_Master_Job"
  }
}

resource "aws_dynamodb_table_item" "master_job_config_day3" {
  for_each = local.master_job_config_seed

  table_name = var.master_job_config_table_name
  hash_key   = "ID"

  item = jsonencode({
    "ID"              = { "N" = each.key }
    "RUN_TYPE"        = { "S" = "NEW" }
    "RERUN_DATE"      = { "S" = "2024-01-01" }
    "BATCH_ID"        = { "N" = "0" }
    "LAST_RUN_DATE"   = { "S" = "2024-01-01" }
    "LAST_RUN_STATUS" = { "S" = "NEW" }
  })
}
