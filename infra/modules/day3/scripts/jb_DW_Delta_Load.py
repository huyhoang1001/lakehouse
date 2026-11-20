"""
jb_DW_Delta_Load.py
------------------------------------------------------------------------------
Day 3 Delta load job (Req 3.4, 3.6).

Reads the bronze Parquet written by Day 1 for --p_src_tableName and writes a
Delta Lake table at <--p_lakehouse_location>/<--p_tar_tablename>.

Argument contract (also supplied as Glue default arguments so a manual run
works) — matches what NT_Accelerate_LakeHouse_Master_Job passes:
  --p_job_name, --p_run_date, --p_batch_id, --p_region,
  --p_lakehouse_location, --p_src_databaseName, --p_src_tableName,
  --p_tar_databaseName, --p_tar_tablename

Run records are written to NT_Accelerate_JOB_LOG and the latest status to
NT_Accelarate_JOB_STATUS (intentional misspelling) via Genericlib, exactly like
the Day 1 jobs.
------------------------------------------------------------------------------
"""

import sys
import uuid
from datetime import datetime

import boto3
from awsglue.context import GlueContext
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
        "p_lakehouse_location",
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
var_lakehouse_location = args["p_lakehouse_location"].rstrip("/")
var_src_table = args["p_src_tableName"]
var_tar_table = args["p_tar_tablename"]

# --p_lakehouse_location is s3://<bucket>/lake/gold/tickit/
# The Day 1 bronze layer lives at s3://<bucket>/lake/bronze/tickit/<table>/
bronze_prefix = var_lakehouse_location.replace("/lake/gold/", "/lake/bronze/")
bronze_path = "{}/{}/".format(bronze_prefix, var_src_table)
delta_path = "{}/{}".format(var_lakehouse_location, var_tar_table)

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

    # Full (overwrite) load into the Delta gold table. `overwriteSchema` lets a
    # schema change in the source land without a manual table drop.
    (
        df.write.format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .save(delta_path)
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
