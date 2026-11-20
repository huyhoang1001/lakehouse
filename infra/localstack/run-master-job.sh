#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Run a Day 2 Step Functions master job against the local stack.
#
#   ./run-master-job.sh                                      # Datalake (staging)
#   ./run-master-job.sh NT_Accelerate_LakeHouse_Master_Job
#   ./run-master-job.sh --no-agent                           # orchestration only
#
# All three master jobs are runnable: the local init hooks seed the
# MASTER_JOB_CONFIG rows they read -- ID=1 (Datalake), ID=2 (LakeHouse) and
# ID=3 (RedshiftDW). In AWS the lab only defines ID=1, so the LakeHouse /
# RedshiftDW jobs fail there; the Terraform module (infra/modules/day3) adds
# IDs 2 and 3 and makes them runnable too.
#
# Run the Datalake job first: the LakeHouse and RedshiftDW jobs gate on
# NT_Accelerate_Check_Staging_Master_Job_Status, which passes only once the
# staging master job has SUCCEEDED for the same run_date (see init/03-day3.sh).
#
# Setup first:  docker compose -f infra/localstack/docker-compose.yml up -d
# (the init hooks create the control tables, the Lambdas and the state machines).
#
# The aws CLI runs *inside* the LocalStack container, so nothing needs to be
# installed on the host.
#
# GLUE: the init hook wires the master jobs' Glue states to one of two local
# stand-ins (see GLUE_MODE in .env / init/02-day2.sh). In the default "bridge"
# mode each Glue state pauses on a task token and this script also runs
# run-glue-agent.sh in the background, which executes the real job with
# run-glue.sh and then resumes the execution -- so a run takes as long as the
# seven Spark jobs do (a few minutes), and its progress is printed as
# `[glue-agent] ...` lines. In "stub" mode nothing is queued, the agent just
# idles, and the run finishes in seconds. --no-agent skips it either way.
#
# Run modes: MASTER_JOB_CONFIG holds the decision. The default row is
# RUN_TYPE=NEW; to exercise the RERUN path, flip it first (see
# docs/local-development.md).
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${LOCALSTACK_CONTAINER:-nt-localstack}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

with_agent=1
STATE_MACHINE=""
for arg in "$@"; do
  case "$arg" in
    --no-agent) with_agent=0 ;;
    -*) echo "ERROR: unknown option '$arg'" >&2; exit 2 ;;
    *) STATE_MACHINE="$arg" ;;
  esac
done
STATE_MACHINE="${STATE_MACHINE:-NT_Accelerate_Datalake_Master_Job}"

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

# The agent drains the Glue hand-off queue for the whole run, however long that
# is, so it is started --forever and stopped when this script exits. In stub
# mode it never finds anything and is equally harmless.
agent_pid=""
if [ "$with_agent" -eq 1 ]; then
  "$HERE/run-glue-agent.sh" --forever &
  agent_pid=$!
  trap 'kill "$agent_pid" 2>/dev/null || true' EXIT
fi

run_name="local-$(date +%Y%m%d-%H%M%S)"
execution_arn="$(awsl stepfunctions start-execution \
  --state-machine-arn "$machine_arn" --name "$run_name" --query executionArn --output text)"
echo "state machine : $STATE_MACHINE"
echo "execution     : $execution_arn"

# Say something while it runs: with the bridge the seven Spark jobs take minutes,
# and the execution status alone would be a silent wait.
elapsed=0
status="RUNNING"
while [ "$status" = "RUNNING" ]; do
  sleep 2
  elapsed=$((elapsed + 2))
  status="$(awsl stepfunctions describe-execution \
    --execution-arn "$execution_arn" --query status --output text)"
  if [ "$status" = "RUNNING" ] && [ $((elapsed % 10)) -eq 0 ]; then
    echo "  ... still RUNNING (${elapsed}s)"
  fi
done

echo "status        : $status"

if [ "$status" != "SUCCEEDED" ]; then
  echo "--- failure cause ---" >&2
  awsl stepfunctions describe-execution --execution-arn "$execution_arn" \
    --query '[cause,error]' --output text >&2
  exit 1
fi
