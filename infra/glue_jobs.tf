# glue_jobs.tf
# -----------------------------------------------------------------------------
# Glue ETL job resources for the NT Accelerate Day 1 ingestion stack.
#
# Resources in this file (by task):
#   - Task 9.1–9.6  aws_glue_job "full_load"   6 full-load jobs via for_each
#   - Task 9.7      aws_glue_job "sales"        incremental Sales job (added in 9.7)
# -----------------------------------------------------------------------------

locals {
  # Map of full-load jobs: each entry maps job name → { src_table, tar_table }.
  # Task 9.7 (jb_Stg_Extract_Sales) is intentionally excluded — it uses
  # p_is_incremental_load = "True" and is a separate resource block.
  full_load_jobs = {
    "jb_Stg_Extract_Category" = { src_table = "tickit_dbo_category", tar_table = "category" }
    "jb_Stg_Extract_Date"     = { src_table = "tickit_dbo_date",     tar_table = "date"     }
    "jb_Stg_Extract_Event"    = { src_table = "tickit_dbo_event",    tar_table = "event"    }
    "jb_Stg_Extract_Listing"  = { src_table = "tickit_dbo_listing",  tar_table = "listing"  }
    "jb_Stg_Extract_Users"    = { src_table = "tickit_dbo_users",    tar_table = "users"    }
    "jb_Stg_Extract_Venue"    = { src_table = "tickit_dbo_venue",    tar_table = "venue"    }
  }
}

# Tasks 9.1–9.6 — Six full-load Glue ETL jobs (refs Req 8)
resource "aws_glue_job" "full_load" {
  for_each = local.full_load_jobs

  name              = each.key
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  timeout           = 30
  connections       = [aws_glue_connection.conRDS_tickit.name]

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.main.bucket}/glue_script/${each.key}.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"       = "job-bookmark-enable"
    "--extra-py-files"            = "s3://${aws_s3_bucket.main.bucket}/library/Genericlib.zip"
    "--additional-python-modules" = "s3://${aws_s3_bucket.main.bucket}/library/openpyxl-3.0.10.tar.gz"
    "--TempDir"                   = "s3://${aws_s3_bucket.main.bucket}/temporary/"
    "--spark-event-logs-path"     = "s3://${aws_s3_bucket.main.bucket}/sparkHistoryLogs/"
    "--enable-spark-ui"           = "true"
    "--p_job_name"                = each.key
    "--p_run_date"                = var.run_date
    "--p_batch_id"                = tostring(var.batch_id)
    "--p_region"                  = var.aws_region
    "--p_is_incremental_load"     = "False"
    "--p_catalog_conn"            = aws_glue_connection.conRDS_tickit.name
    "--p_src_databaseName"        = "tickit"
    "--p_src_tableName"           = each.value.src_table
    "--p_tar_databaseName"        = "s3://${aws_s3_bucket.main.bucket}/lake/bronze/tickit/"
    "--p_tar_tablename"           = each.value.tar_table
  }

  tags = merge(var.tags, {
    Name = each.key
  })
}

# Task 9.7 — jb_Stg_Extract_Sales (incremental) (refs Req 8)
resource "aws_glue_job" "sales" {
  name              = "jb_Stg_Extract_Sales"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  timeout           = 30
  connections       = [aws_glue_connection.conRDS_tickit.name]

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.main.bucket}/glue_script/jb_Stg_Extract_Sales.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"       = "job-bookmark-enable"
    "--extra-py-files"            = "s3://${aws_s3_bucket.main.bucket}/library/Genericlib.zip"
    "--additional-python-modules" = "s3://${aws_s3_bucket.main.bucket}/library/openpyxl-3.0.10.tar.gz"
    "--TempDir"                   = "s3://${aws_s3_bucket.main.bucket}/temporary/"
    "--spark-event-logs-path"     = "s3://${aws_s3_bucket.main.bucket}/sparkHistoryLogs/"
    "--enable-spark-ui"           = "true"
    "--p_job_name"                = "jb_Stg_Extract_Sales"
    "--p_run_date"                = var.run_date
    "--p_batch_id"                = tostring(var.batch_id)
    "--p_region"                  = var.aws_region
    "--p_is_incremental_load"     = "True"
    "--p_catalog_conn"            = aws_glue_connection.conRDS_tickit.name
    "--p_src_databaseName"        = "tickit"
    "--p_src_tableName"           = "tickit_dbo_sales"
    "--p_tar_databaseName"        = "s3://${aws_s3_bucket.main.bucket}/lake/bronze/tickit/"
    "--p_tar_tablename"           = "sales"
  }

  tags = merge(var.tags, {
    Name = "jb_Stg_Extract_Sales"
  })
}

# Task 9.8 — jb_Stg_Extract_ExcelFile (optional flat-file job) (refs Req 10)
# Gated by var.enable_flatfile_job. No JDBC connection needed — reads directly from S3.
resource "aws_glue_job" "excel_file" {
  count = var.enable_flatfile_job ? 1 : 0

  name              = "jb_Stg_Extract_ExcelFile"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  timeout           = 30

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.main.bucket}/glue_script/jb_Stg_Extract_ExcelFile.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"       = "job-bookmark-enable"
    "--extra-py-files"            = "s3://${aws_s3_bucket.main.bucket}/library/Genericlib.zip"
    "--additional-python-modules" = "s3://${aws_s3_bucket.main.bucket}/library/openpyxl-3.0.10.tar.gz"
    "--TempDir"                   = "s3://${aws_s3_bucket.main.bucket}/temporary/"
    "--spark-event-logs-path"     = "s3://${aws_s3_bucket.main.bucket}/sparkHistoryLogs/"
    "--enable-spark-ui"           = "true"
    "--p_job_name"                = "jb_Stg_Extract_ExcelFile"
    "--p_run_date"                = var.run_date
    "--p_batch_id"                = tostring(var.batch_id)
    "--p_region"                  = var.aws_region
    "--p_src_databaseName"        = "tickit"
    "--p_tar_databaseName"        = "s3://${aws_s3_bucket.main.bucket}/lake/bronze/tickit/"
    "--p_tar_tablename"           = "salesevent"
  }

  tags = merge(var.tags, {
    Name = "jb_Stg_Extract_ExcelFile"
  })
}
