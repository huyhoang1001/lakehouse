#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Run a Day 2 Step Functions master job against the local stack.
#
#   ./run-master-job.sh                                      # Datalake (staging)
#   ./run-master-job.sh NT_Accelerate_LakeHouse_Master_Job
#
# Only the Datalake (Staging) master job is runnable out of the box: the lab
# (and the Terraform module) seed exactly one MASTER_JOB_CONFIG row, ID=1, which
# is the Datalake job's. The LakeHouse / RedshiftDW jobs read IDs 2 and 3, which
# the lab never defines, so they fail identically here and in AWS. Seed those
# rows yourself if you want to exercise them.
#
# Setup first:  docker compose -f infra/localstack/docker-compose.yml up -d
# (the init hooks create the control tables, the Lambdas and the state machines).
#
# The aws CLI runs *inside* the LocalStack container, so nothing needs to be
# installed on the host. The script starts an execution and polls until it
# stops, printing the per-state error if it failed.
#
# Run modes: MASTER_JOB_CONFIG holds the decision. The default row is
# RUN_TYPE=NEW; to exercise the RERUN path, flip it first (see
# docs/local-development.md).
# -----------------------------------------------------------------------------
set -euo pipefail

CONTAINER="${LOCALSTACK_CONTAINER:-nt-localstack}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STATE_MACHINE="${1:-NT_Accelerate_Datalake_Master_Job}"

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container '$CONTAINER' is not running." >&2
  echo "Start it with: docker compose -f infra/localstack/docker-compose.yml up -d" >&2
  exit 1
fi

awsl() {
  docker exec "$CONTAINER" aws --endpoint-url http://localhost:4566 --region "$REGION" "$@"
}

machine_arn="$(awsl stepfunctions list-state-machines \
  --query "stateMachines[?name=='$STATE_MACHINE'].stateMachineArn" --output text)"
if [ -z "$machine_arn" ] || [ "$machine_arn" = "None" ]; then
  echo "ERROR: state machine '$STATE_MACHINE' not found." >&2
  echo "Available:" >&2
  awsl stepfunctions list-state-machines --query 'stateMachines[].name' --output text >&2
  exit 1
fi

run_name="local-$(date +%Y%m%d-%H%M%S)"
execution_arn="$(awsl stepfunctions start-execution \
  --state-machine-arn "$machine_arn" --name "$run_name" --query executionArn --output text)"
echo "state machine : $STATE_MACHINE"
echo "execution     : $execution_arn"

status="RUNNING"
while [ "$status" = "RUNNING" ]; do
  sleep 2
  status="$(awsl stepfunctions describe-execution \
    --execution-arn "$execution_arn" --query status --output text)"
done

echo "status        : $status"

if [ "$status" != "SUCCEEDED" ]; then
  echo "--- failure cause ---" >&2
  awsl stepfunctions describe-execution --execution-arn "$execution_arn" \
    --query '[cause,error]' --output text >&2
  exit 1
fi
