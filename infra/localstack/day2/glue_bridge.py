"""
Local-only stand-in for `arn:aws:states:::glue:startJobRun.sync`.

LocalStack's free tier cannot run Glue, so a Day 2 master job would fail at every
"Start job jb_..." state. The local harness rewrites those states to
`lambda:invoke.waitForTaskToken` of this function (see transform_sfn.py), which
turns each one into a *queued* job:

  1. merge the job's static Glue arguments -- the DefaultArguments that
     infra/modules/day1/glue_jobs.tf sets, read from glue_job_defaults.json --
     with the arguments the state computed, the state winning, exactly as the
     Glue service does;
  2. file that, the job name and the Step Functions task token in
     NT_Accelerate_LocalGlueQueue as a PENDING row, and return.

The execution then sits paused on its task token until run-glue-agent.sh --
watching that table -- has actually run the job with run-glue.sh and called
send-task-success (or send-task-failure). So the JOB_LOG / JOB_STATUS rows the
run leaves behind are written by the real job, not by this bridge, and the
staging gate reads real counts.

This file is NOT part of the Terraform deployment: nothing under infra/modules/
references it, and it is mounted into the LocalStack container only.
"""
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

QUEUE = "NT_Accelerate_LocalGlueQueue"
# The manifest travels *inside* the deployment package: LocalStack runs a Lambda
# in its own container, which does not inherit the LocalStack container's mounts,
# so the copy under /opt/day2 is not reachable from here.
DEFAULTS_PATH = os.environ.get(
    "GLUE_JOB_DEFAULTS",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "glue_job_defaults.json"),
)
BUCKET = os.environ.get("BUCKET_NAME", "")

_defaults_cache = None


def _defaults():
    global _defaults_cache
    if _defaults_cache is None:
        try:
            with open(DEFAULTS_PATH) as fh:
                _defaults_cache = json.load(fh).get("jobs", {})
        except OSError as exc:
            # Better to run the job with only the state's arguments than not at
            # all; the missing ones then surface as a getResolvedOptions error in
            # the job's own log. Be loud about it, though: --p_catalog_conn is
            # exactly the argument the state does not send.
            print("WARNING: cannot read %s (%s); no Glue defaults applied" % (DEFAULTS_PATH, exc))
            _defaults_cache = {}
    return _defaults_cache


def _merge(job_name, state_args):
    """Glue merges a job's DefaultArguments with the Arguments of a run, the run
    winning. Reproduce that so the script sees what it would see in the cloud --
    including arguments the state never sends, notably --p_catalog_conn (the
    state spells it --catalog_conn)."""
    merged = {}
    for key, value in _defaults().get(job_name, {}).items():
        merged[key] = str(value).replace("{bucket}", BUCKET)
    for key, value in state_args.items():
        merged[key] = "" if value is None else str(value)
    # The Glue service injects JOB_NAME; nothing else supplies it, and every job
    # script asks for it in getResolvedOptions.
    merged["--JOB_NAME"] = job_name
    return merged


def lambda_handler(event, context):
    token = event.pop("task_token", None)
    job_name = event.pop("JobName", None) or event.get("--p_job_name")
    if not token or not job_name:
        raise ValueError("payload must carry JobName and task_token")

    args = _merge(job_name, {k: v for k, v in event.items() if k.startswith("--")})
    # run-glue.sh takes the arguments as a plain argv tail, so flatten the map
    # into one string. No argument value contains whitespace, so it survives the
    # round trip through DynamoDB intact.
    argv = " ".join(f"{key} {value}" for key, value in args.items())

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    boto3.client(
        "dynamodb",
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        # Explicit, so this also works on a runtime whose boto3 predates the
        # AWS_ENDPOINT_URL environment variable.
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL"),
    ).put_item(
        TableName=QUEUE,
        Item={
            "ID": {"S": str(uuid.uuid4())},
            "JOB_NAME": {"S": job_name},
            "ARGS": {"S": argv},
            "TASK_TOKEN": {"S": token},
            "STATUS": {"S": "PENDING"},
            "BATCH_ID": {"S": str(args.get("--p_batch_id", ""))},
            "RUN_DATE": {"S": str(args.get("--p_run_date", ""))},
            "CREATED": {"S": now},
        },
    )
    return {"job_name": job_name, "status": "QUEUED"}
