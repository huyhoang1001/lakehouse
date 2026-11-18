# locals.tf
# -----------------------------------------------------------------------------
# Commonly referenced names, paths, and identifiers reused across Day 2 task
# files.
#
# DynamoDB table names are spelled EXACTLY as the Lambda source code references
# them, including the intentional misspellings carried over from Day 1:
#   - NT_Accelarate_JOB_STATUS       (missing 'e' in "Accelerate")
#   - NT_Acccelarate_WATERMARKTABLE  (triple 'c' and missing 'e' in "Accelerate")
# Do NOT "fix" these spellings or Lambda functions will fail with
# ResourceNotFoundException at runtime.
# -----------------------------------------------------------------------------

locals {

  # ---------------------------------------------------------------------------
  # DynamoDB table names
  # ---------------------------------------------------------------------------

  # Carried over from Day 1 — spellings must match Genericlib.py exactly.
  ddb_job_config = "NT_Accelerate_JOB_CONFIG"      # correct spelling
  ddb_job_log    = "NT_Accelerate_JOB_LOG"         # correct spelling
  ddb_job_status = "NT_Accelarate_JOB_STATUS"      # missing 'e' in Accelerate (intentional)
  ddb_watermark  = "NT_Acccelarate_WATERMARKTABLE" # triple 'c', missing 'e' (intentional)

  # New Day 2 tables — correct spellings.
  ddb_master_job_config = "NT_Accelerate_MASTER_JOB_CONFIG"
  ddb_mail_config       = "NT_Accelerate_Mail_Config"

  # ---------------------------------------------------------------------------
  # Lambda function names (stripped of .py extension)
  # ---------------------------------------------------------------------------

  lambda_function_names = [
    "NT_Accelerate_Read_Run_Type",
    "NT_Accelerate_Check_Job_Status",
    "NT_Accelerate_Truncate_Job_Status",
    "NT_Accelerate_Is_Allow_Running",
    "NT_Accelerate_Check_Job_ReRun",
    "NT_Accelerate_Update_Job_Status",
    "NT_Accelerate_Update_MasterJob_Status",
    "NT_Accelerate_Check_Staging_Master_Job_Status",
    "NT_Accelerate_Send_Mail",
  ]

  # ---------------------------------------------------------------------------
  # Source file paths
  # ---------------------------------------------------------------------------

  # Directory containing all nine Lambda .py source files.
  lambda_source_dir = "${path.module}/../../../instruction/day2/Day 2 source 2/Day 2 source/Lambda"

  # Directory containing the three Step Functions JSON definition files.
  sfn_def_dir = "${path.module}/../../../instruction/day2/Day 2 source 2/Day 2 source/Step function"

  # ---------------------------------------------------------------------------
  # S3 prefixes
  # ---------------------------------------------------------------------------

  # Prefix under which Lambda ZIP packages are stored in the Day 1 bucket.
  s3_lambda_prefix = "lambda/"
}
