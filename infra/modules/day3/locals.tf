# locals.tf
# -----------------------------------------------------------------------------
# Names, S3 paths, and the Day 3 job inventory reused across the module.
#
# DynamoDB table names are spelled EXACTLY as Genericlib.py and the Day 2
# Lambdas reference them, including the intentional misspellings carried over
# from Day 1:
#   - NT_Accelarate_JOB_STATUS       (missing 'e' in "Accelerate")
#   - NT_Acccelarate_WATERMARKTABLE  (triple 'c' and missing 'e' in "Accelerate")
# Do NOT "fix" these spellings — the Glue jobs would fail with
# ResourceNotFoundException at runtime.
# -----------------------------------------------------------------------------

locals {
  project_name = "NT_Accelerate"

  # --- DynamoDB control tables -------------------------------------------------
  # Spellings must match Genericlib.py exactly (typos intentional, see header).
  ddb_job_config = "NT_Accelerate_JOB_CONFIG"      # correct spelling
  ddb_job_log    = "NT_Accelerate_JOB_LOG"         # correct spelling
  ddb_job_status = "NT_Accelarate_JOB_STATUS"      # missing 'e' in Accelerate (intentional)
  ddb_watermark  = "NT_Acccelarate_WATERMARKTABLE" # triple 'c', missing 'e' (intentional)

  # --- Redshift ----------------------------------------------------------------
  redshift_connection_name = "conRedshift_tickit"
  redshift_port            = 5439
  redshift_secret_name     = "Redshift_Database_Connection_Info"
  redshift_cluster_id      = "${replace(lower(local.project_name), "_", "-")}-redshift"

  # --- S3 (Day 1 bucket) -------------------------------------------------------
  s3_glue_script_prefix = "glue_script/"
  s3_library_prefix     = "library/"
  s3_bronze_prefix      = "lake/bronze/tickit/"
  s3_gold_prefix        = "lake/gold/tickit/"
  s3_temporary_prefix   = "temporary/"

  # Gold location passed to the Delta jobs as --p_lakehouse_location.
  lakehouse_location = "s3://${var.bucket_name}/${local.s3_gold_prefix}"
  temporary_location = "s3://${var.bucket_name}/${local.s3_temporary_prefix}"

  # --- Delta runtime -----------------------------------------------------------
  delta_jar_key    = "library/delta-spark_2.13-4.1.0.jar"
  delta_jar_source = "${path.module}/../../../instruction/day1/delta-spark_2.13-4.1.0.jar.txt"
  delta_jar_uri    = "s3://${var.bucket_name}/${local.delta_jar_key}"

  # --- Authored Glue transform scripts -----------------------------------------
  scripts_dir          = "${path.module}/scripts"
  delta_script_file    = "jb_DW_Delta_Load.py"
  redshift_script_file = "jb_DW_Redshift_Load.py"

  # --- Day 3 job inventory -----------------------------------------------------
  # Delta jobs write Delta tables under the gold location; the target table name
  # is the map key (e.g. "DateDim"). `id` is the JOB_CONFIG primary key.
  delta_jobs = {
    "DateDim"     = { id = "8", src_table = "date" }
    "VenueDim"    = { id = "9", src_table = "venue" }
    "CategoryDim" = { id = "10", src_table = "category" }
    "UserDim"     = { id = "11", src_table = "users" }
    "EventDim"    = { id = "12", src_table = "event" }
    "SalesFact"   = { id = "13", src_table = "sales" }
  }

  # Redshift jobs load the warehouse tables. `src_table` is the bronze table;
  # `trg_table` is the Redshift target table.
  redshift_jobs = {
    "DateDim"     = { id = "14", src_table = "date", trg_table = "dim_date" }
    "VenueDim"    = { id = "15", src_table = "venue", trg_table = "dim_venue" }
    "CategoryDim" = { id = "16", src_table = "category", trg_table = "dim_category" }
    "UserDim"     = { id = "17", src_table = "users", trg_table = "dim_user" }
    "EventDim"    = { id = "18", src_table = "event", trg_table = "dim_event" }
    "SalesFact"   = { id = "19", src_table = "sales", trg_table = "fact_sales" }
  }
}
