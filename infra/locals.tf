# locals.tf
# -----------------------------------------------------------------------------
# Commonly referenced names and S3 prefixes reused across later task files.
#
# DynamoDB table names are spelled EXACTLY as Genericlib.py references them,
# including the intentional misspellings:
#   - NT_Accelarate_JOB_STATUS       (missing 'e' in "Accelerate")
#   - NT_Acccelarate_WATERMARKTABLE  (triple 'c' and missing 'e' in "Accelerate")
# Do NOT "fix" these spellings or jobs will fail with ResourceNotFoundException
# at runtime.
# -----------------------------------------------------------------------------

locals {
  project_name = "NT_Accelerate"

  # IAM
  glue_role_name = "NT_Accelerate_GlueRole"

  # Secrets Manager
  secret_name = "SQLSource_Database_Connection_Info"

  # Glue catalog, connection, and crawler
  glue_database_name   = "tickit"
  glue_connection_name = "conRDS_tickit"
  crawler_name         = "NT_Accelerate_cwl_RDSTickit"

  # DynamoDB control tables — exact spellings matching Genericlib.py (typos intentional)
  ddb_job_config = "NT_Accelerate_JOB_CONFIG"      # correct spelling
  ddb_job_log    = "NT_Accelerate_JOB_LOG"         # correct spelling
  ddb_job_status = "NT_Accelarate_JOB_STATUS"      # missing 'e' in Accelerate (intentional)
  ddb_watermark  = "NT_Acccelarate_WATERMARKTABLE" # triple 'c', missing 'e' (intentional)

  # S3 key prefixes
  s3_glue_script_prefix = "glue_script/"
  s3_library_prefix     = "library/"
  s3_raw_prefix         = "raw/"
  s3_lake_prefix        = "lake/bronze/tickit/"
  s3_spark_logs_prefix  = "sparkHistoryLogs/"
  s3_temp_prefix        = "temporary/"

  # Glue job names — the 6 full-load jobs plus the incremental Sales job.
  # The optional flat-file job (jb_Stg_Extract_ExcelFile) is gated separately by
  # var.enable_flatfile_job and is intentionally excluded from this list.
  glue_job_names = [
    "jb_Stg_Extract_Category",
    "jb_Stg_Extract_Date",
    "jb_Stg_Extract_Event",
    "jb_Stg_Extract_Listing",
    "jb_Stg_Extract_Users",
    "jb_Stg_Extract_Venue",
    "jb_Stg_Extract_Sales",
  ]
}
