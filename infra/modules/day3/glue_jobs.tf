# glue_jobs.tf
# -----------------------------------------------------------------------------
# Day 3 Glue jobs and their script uploads.
#
#   - Delta   : jb_DW_Delta_Load_{DateDim,VenueDim,CategoryDim,UserDim,EventDim,SalesFact}
#   - Redshift: jb_DW_Redshift_Load_{DateDim,VenueDim,CategoryDim,UserDim,EventDim,SalesFact}
#
# Job names match exactly what NT_Accelerate_LakeHouse_Master_Job and
# NT_Accelerate_RedshiftDW_Master_Job start (Req 3.1, 5.1). The default_arguments
# carry every key the master jobs pass, so a manual run also works.
# `glue_version`, `worker_type`, `number_of_workers`, `max_retries`, and `timeout`
# follow the Day 1 conventions (Req 3.5).
#
# NOTE (highest-risk item from the design): the provided delta-spark jar is a
# Scala 2.13 / Spark 4.x build while Glue 3.0 ships Spark 3.x / Scala 2.12.
# Confirm the ABI match (or substitute a Glue-compatible Delta jar) before
# running the Delta jobs end to end.
# -----------------------------------------------------------------------------

# --- Script uploads (Req 3.2, 5.2) -------------------------------------------

resource "aws_s3_object" "delta_script" {
  bucket = var.bucket_name
  key    = "${local.s3_glue_script_prefix}${local.delta_script_file}"
  source = "${local.scripts_dir}/${local.delta_script_file}"
  etag   = filemd5("${local.scripts_dir}/${local.delta_script_file}")
}

resource "aws_s3_object" "redshift_script" {
  bucket = var.bucket_name
  key    = "${local.s3_glue_script_prefix}${local.redshift_script_file}"
  source = "${local.scripts_dir}/${local.redshift_script_file}"
  etag   = filemd5("${local.scripts_dir}/${local.redshift_script_file}")
}

# --- Delta load jobs (Req 3) -------------------------------------------------

resource "aws_glue_job" "delta" {
  for_each = local.delta_jobs

  name              = "jb_DW_Delta_Load_${each.key}"
  role_arn          = var.glue_role_arn
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  timeout           = 30

  execution_property {
    max_concurrent_runs = 1
  }

  command {
    name            = "glueetl"
    script_location = "s3://${var.bucket_name}/${local.s3_glue_script_prefix}${local.delta_script_file}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"     = "job-bookmark-disable"
    "--extra-py-files"          = "s3://${var.bucket_name}/library/Genericlib.zip"
    "--extra-jars"              = local.delta_jar_uri
    "--TempDir"                 = local.temporary_location
    "--spark-event-logs-path"   = "s3://${var.bucket_name}/sparkHistoryLogs/"
    "--enable-spark-ui"         = "true"
    "--enable-glue-datacatalog" = "true"
    # Register the Delta Spark session extension + catalog.
    "--conf" = "spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog"

    "--p_job_name"           = "jb_DW_Delta_Load_${each.key}"
    "--p_run_date"           = var.run_date
    "--p_batch_id"           = tostring(var.batch_id)
    "--p_region"             = var.aws_region
    "--p_lakehouse_location" = local.lakehouse_location
    "--p_src_databaseName"   = var.glue_database_name
    "--p_src_tableName"      = each.value.src_table
    "--p_tar_databaseName"   = local.lakehouse_location
    "--p_tar_tablename"      = each.key
  }

  tags = merge(var.tags, {
    Name = "jb_DW_Delta_Load_${each.key}"
  })

  depends_on = [
    aws_s3_object.delta_jar,
    aws_s3_object.delta_script,
  ]
}

# --- Redshift load jobs (Req 5) ----------------------------------------------
# Gated by enable_redshift: without the cluster/connection there is nothing to
# load. `for_each` over an empty map keeps the resource absent when disabled.

resource "aws_glue_job" "redshift" {
  for_each = var.enable_redshift ? local.redshift_jobs : {}

  name              = "jb_DW_Redshift_Load_${each.key}"
  role_arn          = var.glue_role_arn
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  timeout           = 30

  execution_property {
    max_concurrent_runs = 1
  }

  connections = [aws_glue_connection.conRedshift_tickit[0].name]

  command {
    name            = "glueetl"
    script_location = "s3://${var.bucket_name}/${local.s3_glue_script_prefix}${local.redshift_script_file}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"     = "job-bookmark-disable"
    "--extra-py-files"          = "s3://${var.bucket_name}/library/Genericlib.zip"
    "--TempDir"                 = local.temporary_location
    "--spark-event-logs-path"   = "s3://${var.bucket_name}/sparkHistoryLogs/"
    "--enable-spark-ui"         = "true"
    "--enable-glue-datacatalog" = "true"

    "--p_job_name"         = "jb_DW_Redshift_Load_${each.key}"
    "--p_run_date"         = var.run_date
    "--p_batch_id"         = tostring(var.batch_id)
    "--p_region"           = var.aws_region
    "--p_src_databaseName" = var.glue_database_name
    "--p_src_tableName"    = each.value.src_table
    "--p_tar_databaseName" = var.redshift_database_name
    "--p_tar_tablename"    = each.value.trg_table
    "--p_catalog_con"      = local.redshift_connection_name
    "--p_prescript"        = "drop table if exists ${each.value.trg_table}"
    "--p_postscript"       = "analyze ${each.value.trg_table}"
    "--p_redshift_temp"    = local.temporary_location
  }

  tags = merge(var.tags, {
    Name = "jb_DW_Redshift_Load_${each.key}"
  })

  depends_on = [
    aws_glue_connection.conRedshift_tickit,
    aws_s3_object.redshift_script,
  ]
}
