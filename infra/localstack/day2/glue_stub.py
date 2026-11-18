"""
Local-only stand-in for `arn:aws:states:::glue:startJobRun.sync`.

LocalStack's free tier cannot run Glue, so the Day 2 master jobs would fail at
every "Start job jb_..." state. The local harness rewrites those states to
invoke this Lambda instead (see transform_sfn.py). It records the two DynamoDB
rows a real Glue job writes when it runs -- one in JOB_LOG and one in
JOB_STATUS -- both marked SUCCEEDED, so the orchestration around them (run type,
the NEW/RERUN decision, the parallel fan-out, the staging gate and the SES
mail) can be exercised end-to-end without an AWS account.

This file is NOT part of the Terraform deployment: nothing under
infra/modules/ references it, and it is mounted into the LocalStack container
only.
"""
import os
import uuid
from datetime import datetime, timezone

import boto3

TBL_JOB_LOG = "NT_Accelerate_JOB_LOG"
TBL_JOB_STATUS = "NT_Accelarate_JOB_STATUS"  # intentional misspelling (matches Genericlib.py)

# Makes it obvious, when scanning the tables, that no real Glue job ran.
NOTE = "local stub: Glue job not executed (LocalStack cannot run Glue)"


def lambda_handler(event, context):
    # The Glue state's "Arguments" map arrives verbatim as the Lambda payload.
    job_name = event.get("--p_job_name", "unknown")
    batch_id = str(event.get("--p_batch_id", "0"))
    run_date = event.get("--p_run_date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    client = boto3.client(
        "dynamodb",
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        # Passing it explicitly keeps this working on runtimes whose boto3
        # predates the AWS_ENDPOINT_URL environment variable.
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL"),
    )

    client.put_item(
        TableName=TBL_JOB_LOG,
        Item={
            "ID": {"S": str(uuid.uuid4())},
            "JOB_NAME": {"S": job_name},
            "BATCH_ID": {"N": batch_id},
            "RUN_DATE": {"S": run_date},
            "SOURCE_COUNT": {"N": "0"},
            "TARGET_COUNT": {"N": "0"},
            "PROCESS_STATUS": {"S": "SUCCEEDED"},
            "ERROR_MSG": {"S": NOTE},
            "START_RUN": {"S": now},
            "END_RUN": {"S": now},
        },
    )
    client.put_item(
        TableName=TBL_JOB_STATUS,
        Item={
            "JOB_NAME": {"S": job_name},
            "BATCH_ID": {"N": batch_id},
            "RUN_DATE": {"S": run_date},
            "PROCESS_STATUS": {"S": "SUCCEEDED"},
            "ERROR_MSG": {"S": NOTE},
        },
    )
    return {"job_name": job_name, "status": "SUCCEEDED", "stub": True}
