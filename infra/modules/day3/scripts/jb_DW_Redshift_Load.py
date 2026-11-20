"""
jb_DW_Redshift_Load.py
------------------------------------------------------------------------------
Day 3 Redshift load job (Req 5.4, 5.5).

Reads the bronze Parquet written by Day 1 for --p_src_tableName and loads the
Redshift table <--p_tar_databaseName>.<--p_tar_tablename> through the Glue JDBC
connection --p_catalog_con. --p_redshift_temp is the S3 staging area Redshift
uses for the COPY/UNLOAD; --p_prescript / --p_postscript run around the load.

Argument contract (also supplied as Glue default arguments) — matches what
NT_Accelerate_RedshiftDW_Master_Job passes:
  --p_job_name, --p_run_date, --p_batch_id, --p_region,
  --p_src_databaseName, --p_src_tableName, --p_tar_databaseName,
  --p_tar_tablename, --p_catalog_con, --p_prescript, --p_postscript,
  --p_redshift_temp

Run records are written to NT_Accelerate_JOB_LOG and the latest status to
NT_Accelarate_JOB_STATUS (intentional misspelling) via Genericlib.
------------------------------------------------------------------------------
"""

import sys
import uuid
from datetime import datetime

import boto3
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext

import Genericlib as gl

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "p_job_name",
        "p_run_date",
        "p_batch_id",
        "p_region",
        "p_catalog_con",
        "p_prescript",
        "p_postscript",
        "p_redshift_temp",
        "p_src_databaseName",
        "p_src_tableName",
        "p_tar_databaseName",
        "p_tar_tablename",
    ],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# --- Resolved parameters ------------------------------------------------------
var_job_name = args["p_job_name"]
var_run_date = args["p_run_date"]
var_batch_id = args["p_batch_id"]
var_region = args["p_region"]
var_catalog_con = args["p_catalog_con"]
var_prescript = args["p_prescript"]
var_postscript = args["p_postscript"]
var_redshift_temp = args["p_redshift_temp"].rstrip("/") + "/"
var_src_db = args["p_src_databaseName"]
var_src_table = args["p_src_tableName"]
var_tar_db = args["p_tar_databaseName"]
var_tar_table = args["p_tar_tablename"]

# --p_redshift_temp is s3://<bucket>/temporary/ — the bucket also holds bronze.
bucket = var_redshift_temp.split("/")[2]
bronze_path = "s3://{}/lake/bronze/{}/{}/".format(bucket, var_src_db, var_src_table)

'''##############################MAIN##########################################'''
dynamodb = boto3.client("dynamodb", region_name=var_region)
start_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
end_run = ""

src_count = 0
trg_count = 0
process_status = ""
id = uuid.uuid1()

try:
    # Read all bronze partitions for this table (Parquet, written by Day 1).
    df = spark.read.parquet(bronze_path)
    src_count = df.count()
    dfSource = DynamicFrame.fromDF(df, glueContext, "redshift_datasource")

    # preactions/postactions only when the JOB_CONFIG row provided them.
    connection_options = {
        "dbtable": var_tar_table,
        "database": var_tar_db,
    }
    if var_prescript:
        connection_options["preactions"] = var_prescript
    if var_postscript:
        connection_options["postactions"] = var_postscript

    # Loads the frame into Redshift via the Glue connection; Redshift stages the
    # COPY through var_redshift_temp.
    glueContext.write_dynamic_frame.from_jdbc_conf(
        frame=dfSource,
        catalog_connection=var_catalog_con,
        connection_options=connection_options,
        redshift_tmp_dir=var_redshift_temp,
        transformation_ctx="redshift_datasink",
    )
    trg_count = src_count

    process_status = "SUCCEEDED"
    end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
    gl.WriteLog(dynamodb, str(id), var_job_name, str(var_batch_id), var_run_date, str(src_count), str(trg_count), process_status, "", start_run, end_run)
    gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status, "")
except Exception as e:
    error_msg = getattr(e, "message", repr(e))
    process_status = "FAILED"
    end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
    gl.WriteLog(dynamodb, str(id), var_job_name, str(var_batch_id), var_run_date, str(src_count), str(trg_count), process_status, error_msg, start_run, end_run)
    gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status, error_msg)
    sys.exit(0)

job.commit()
