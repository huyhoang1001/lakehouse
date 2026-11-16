# dynamodb.tf
# -----------------------------------------------------------------------------
# Four DynamoDB control tables used by the NT Accelerate Glue jobs via Genericlib.py.
#
# IMPORTANT: table names are taken from locals.tf and include intentional typos
# that match Genericlib.py exactly. Do NOT "fix" the spellings or jobs will fail
# with ResourceNotFoundException at runtime.
#
#   NT_Accelarate_JOB_STATUS       — missing 'e' in "Accelerate"
#   NT_Acccelarate_WATERMARKTABLE  — triple 'c' and missing 'e' in "Accelerate"
#
# Tasks 7.1–7.4 (refs Req 6)
# -----------------------------------------------------------------------------

# Task 7.1 — JOB_CONFIG (PK: ID, type N)
resource "aws_dynamodb_table" "job_config" {
  name         = local.ddb_job_config # "NT_Accelerate_JOB_CONFIG"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "ID"

  attribute {
    name = "ID"
    type = "N"
  }

  tags = merge(var.tags, {
    Name = local.ddb_job_config
  })
}

# Task 7.2 — JOB_LOG (PK: ID, type S)
resource "aws_dynamodb_table" "job_log" {
  name         = local.ddb_job_log # "NT_Accelerate_JOB_LOG"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "ID"

  attribute {
    name = "ID"
    type = "S"
  }

  tags = merge(var.tags, {
    Name = local.ddb_job_log
  })
}

# Task 7.3 — JOB_STATUS (PK: JOB_NAME, type S)
# Table name intentionally misspelled: NT_Accelarate_JOB_STATUS (missing 'e')
resource "aws_dynamodb_table" "job_status" {
  name         = local.ddb_job_status # "NT_Accelarate_JOB_STATUS"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "JOB_NAME"

  attribute {
    name = "JOB_NAME"
    type = "S"
  }

  tags = merge(var.tags, {
    Name = local.ddb_job_status
  })
}

# Task 7.4 — WATERMARKTABLE (PK: ID N, SK: JOB_NAME S)
# Table name intentionally misspelled: NT_Acccelarate_WATERMARKTABLE (triple 'c', missing 'e')
resource "aws_dynamodb_table" "watermark" {
  name         = local.ddb_watermark # "NT_Acccelarate_WATERMARKTABLE"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "ID"
  range_key = "JOB_NAME"

  attribute {
    name = "ID"
    type = "N"
  }

  attribute {
    name = "JOB_NAME"
    type = "S"
  }

  tags = merge(var.tags, {
    Name = local.ddb_watermark
  })
}

# Task 7.5 — Seed JOB_CONFIG rows (one per Glue job)
# -----------------------------------------------------------------------------
# Uses for_each over a local map keyed by numeric ID string so Terraform can
# track each item independently. The S3 path interpolates the bucket name from
# aws_s3_bucket.main at plan time.
# -----------------------------------------------------------------------------

locals {
  job_config_items = {
    "1" = {
      job_name         = "jb_Stg_Extract_Category"
      src_table        = "tickit_dbo_category"
      tar_table        = "category"
      is_incremental   = "False"
    }
    "2" = {
      job_name         = "jb_Stg_Extract_Date"
      src_table        = "tickit_dbo_date"
      tar_table        = "date"
      is_incremental   = "False"
    }
    "3" = {
      job_name         = "jb_Stg_Extract_Event"
      src_table        = "tickit_dbo_event"
      tar_table        = "event"
      is_incremental   = "False"
    }
    "4" = {
      job_name         = "jb_Stg_Extract_Listing"
      src_table        = "tickit_dbo_listing"
      tar_table        = "listing"
      is_incremental   = "False"
    }
    "5" = {
      job_name         = "jb_Stg_Extract_Users"
      src_table        = "tickit_dbo_users"
      tar_table        = "users"
      is_incremental   = "False"
    }
    "6" = {
      job_name         = "jb_Stg_Extract_Venue"
      src_table        = "tickit_dbo_venue"
      tar_table        = "venue"
      is_incremental   = "False"
    }
    "7" = {
      job_name         = "jb_Stg_Extract_Sales"
      src_table        = "tickit_dbo_sales"
      tar_table        = "sales"
      is_incremental   = "True"
    }
  }
}

resource "aws_dynamodb_table_item" "job_config" {
  for_each   = local.job_config_items
  table_name = aws_dynamodb_table.job_config.name
  hash_key   = aws_dynamodb_table.job_config.hash_key

  item = jsonencode({
    "ID"                    = { "N" = each.key }
    "JOB_NAME"              = { "S" = each.value.job_name }
    "p_src_tableName"       = { "S" = each.value.src_table }
    "p_tar_tablename"       = { "S" = each.value.tar_table }
    "p_is_incremental_load" = { "S" = each.value.is_incremental }
    "p_region"              = { "S" = "us-east-1" }
    "p_src_databaseName"    = { "S" = "tickit" }
    "p_tar_databaseName"    = { "S" = "s3://${aws_s3_bucket.main.bucket}/lake/bronze/tickit/" }
    "p_catalog_conn"        = { "S" = "conRDS_tickit" }
  })
}

# Task 7.6 — Seed WATERMARKTABLE with the Sales watermark row
# -----------------------------------------------------------------------------
# ID=0 is the initial high-water mark for the incremental Sales job.
# COLUMN_NAMES, DATA_TYPES, and DATA_VALUES are DynamoDB List (L) attributes.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table_item" "watermark_sales" {
  table_name = aws_dynamodb_table.watermark.name
  hash_key   = aws_dynamodb_table.watermark.hash_key
  range_key  = aws_dynamodb_table.watermark.range_key

  item = jsonencode({
    "ID"           = { "N" = "0" }
    "JOB_NAME"     = { "S" = "jb_Stg_Extract_Sales" }
    "COLUMN_NAMES" = { "L" = [{ "S" = "saletime" }] }
    "DATA_TYPES"   = { "L" = [{ "S" = "STRING" }] }
    "DATA_VALUES"  = { "L" = [{ "S" = "2008-12-31 12:58:19" }] }
    "QUERY_STRING" = { "S" = "select sellername, buyername, eventid, dateid, qtysold, pricepaid, commission, saletime from dbo.sales where " }
  })
}
