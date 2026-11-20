#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Local Glue job agent -- the other half of the free-tier bridge.
#
# LocalStack cannot run Glue, so the Day 2 master jobs cannot use
# `glue:startJobRun.sync`. The harness rewrites each Glue state to
# `lambda:invoke.waitForTaskToken` of day2/glue_bridge.py, which files the job in
# NT_Accelerate_LocalGlueQueue and returns; the execution stays paused on its
# task token.
#
# This script drains that table: it claims a queued job, runs it for real with
# run-glue.sh -- the AWS Glue 4.0 image wired to LocalStack and the local SQL
# Server, the same path the Day 1 jobs use -- and then calls send-task-success /
# send-task-failure to resume the execution. So the master jobs drive real Glue
# jobs, and the JOB_LOG / JOB_STATUS rows they gate on are written by those jobs.
#
# Usage:
#   ./run-glue-agent.sh               # exit once the queue has been idle for
#                                     # GLUE_AGENT_IDLE_TIMEOUT seconds
#   ./run-glue-agent.sh --forever     # never exit on an idle queue
#
# Env:
#   GLUE_AGENT_CONCURRENCY   jobs to run at once (default 2)
#   GLUE_AGENT_IDLE_TIMEOUT  empty-queue seconds before exiting (default 30)
#   LOCALSTACK_CONTAINER     default nt-localstack
#
# Each job's output is teed to /tmp/nt-glue-agent/<job>-<id>.log; this terminal
# gets a one-line start/finish summary, plus the log tail when a job fails.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${LOCALSTACK_CONTAINER:-nt-localstack}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TABLE="${GLUE_QUEUE_TABLE:-NT_Accelerate_LocalGlueQueue}"
CONCURRENCY="${GLUE_AGENT_CONCURRENCY:-2}"
IDLE_TIMEOUT="${GLUE_AGENT_IDLE_TIMEOUT:-30}"
LOG_DIR="${GLUE_AGENT_LOG_DIR:-/tmp/nt-glue-agent}"

forever=0
if [ "${1:-}" = "--forever" ]; then
  forever=1
fi

mkdir -p "$LOG_DIR"

log() { echo "[glue-agent] $*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
  log "ERROR: container '$CONTAINER' is not running."
  log "Start it with: docker compose -f infra/localstack/docker-compose.yml up -d"
  exit 1
fi

# The aws CLI lives in the LocalStack container, so the host needs nothing.
awsl() {
  docker exec "$CONTAINER" aws --endpoint-url http://localhost:4566 --region "$REGION" "$@"
}

running_count() { jobs -rp | wc -l | tr -d ' '; }

field() { # field <id> <Attribute>
  awsl dynamodb get-item --table-name "$TABLE" --key "{\"ID\":{\"S\":\"$1\"}}" \
    --query "Item.$2.S" --output text
}

set_status() { # set_status <id> <STATUS>
  awsl dynamodb update-item --table-name "$TABLE" --key "{\"ID\":{\"S\":\"$1\"}}" \
    --update-expression 'SET #s = :s, FINISHED = :now' \
    --expression-attribute-names '{"#s":"STATUS"}' \
    --expression-attribute-values "{\":s\":{\"S\":\"$2\"},\":now\":{\"S\":\"$(now)\"}}" \
    >/dev/null
}

# Claim one PENDING row and print its ID; return 1 if there is nothing to claim
# (or if a second agent claimed it first).
claim_one() {
  local id
  id="$(awsl dynamodb scan --table-name "$TABLE" \
    --filter-expression '#s = :pending' \
    --expression-attribute-names '{"#s":"STATUS"}' \
    --expression-attribute-values '{":pending":{"S":"PENDING"}}' \
    --query 'Items[0].ID.S' --output text 2>/dev/null || true)"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    return 1
  fi
  # The condition makes the claim atomic, so concurrent agents cannot both take
  # the same job.
  if awsl dynamodb update-item --table-name "$TABLE" \
      --key "{\"ID\":{\"S\":\"$id\"}}" \
      --update-expression 'SET #s = :running, CLAIMED = :now' \
      --condition-expression '#s = :pending' \
      --expression-attribute-names '{"#s":"STATUS"}' \
      --expression-attribute-values \
        "{\":running\":{\"S\":\"RUNNING\"},\":pending\":{\"S\":\"PENDING\"},\":now\":{\"S\":\"$(now)\"}}" \
      >/dev/null 2>&1; then
    printf '%s' "$id"
    return 0
  fi
  return 1
}

# Resuming the paused execution. The `output` parameter of SendTaskSuccess
# collides with the AWS CLI's own global --output, so it has to go through
# --cli-input-json instead of --output.
task_success() { # task_success <token> <output-json>
  awsl stepfunctions send-task-success \
    --cli-input-json "{\"taskToken\":\"$1\",\"output\":$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
}

run_one() {
  local id="$1" job_name args token logfile rc=0
  job_name="$(field "$id" JOB_NAME)"
  args="$(field "$id" ARGS)"
  token="$(field "$id" TASK_TOKEN)"
  logfile="$LOG_DIR/${job_name}-${id%%-*}.log"
  [ "$args" = "None" ] && args=""

  log "start  $job_name ($id)"
  {
    echo "--- $job_name  id=$id  $(now) ---"
    echo "run-glue.sh ${job_name}.py $args"
    echo
  } >"$logfile"

  # $args is deliberately unquoted: run-glue.sh takes the arguments as a plain
  # argv tail, and no Glue argument value contains whitespace. The script
  # filename is the job name, exactly as glue_jobs.tf's script_location has it.
  # shellcheck disable=SC2086
  "$HERE/run-glue.sh" "${job_name}.py" $args >>"$logfile" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    set_status "$id" SUCCEEDED
    if ! task_success "$token" "{\"job_name\":\"$job_name\",\"status\":\"SUCCEEDED\"}" >/dev/null; then
      log "WARN: send-task-success failed for $job_name (execution already finished?)"
    fi
    log "done   $job_name ($id) SUCCEEDED  -- log: $logfile"
  else
    set_status "$id" FAILED
    log "FAILED $job_name ($id) exit=$rc -- log: $logfile (tail follows)"
    tail -n 20 "$logfile" >&2 || true
    if ! awsl stepfunctions send-task-failure --task-token "$token" \
      --error "GlueJobFailed" \
      --cause "local Glue job $job_name exited $rc; see $logfile" >/dev/null; then
      log "WARN: send-task-failure failed for $job_name (execution already finished?)"
    fi
  fi
}

idle=0
if [ "$forever" -eq 1 ]; then
  log "watching $TABLE (concurrency $CONCURRENCY, forever)"
else
  log "watching $TABLE (concurrency $CONCURRENCY, idle-timeout ${IDLE_TIMEOUT}s)"
fi

while :; do
  # Wait for a free slot before taking on more work.
  while [ "$(running_count)" -ge "$CONCURRENCY" ]; do
    sleep 1
  done

  if id="$(claim_one)"; then
    idle=0
    run_one "$id" &
  else
    if [ "$(running_count)" -eq 0 ]; then
      idle=$((idle + 1))
      if [ "$forever" -eq 0 ] && [ "$idle" -ge "$IDLE_TIMEOUT" ]; then
        log "queue empty for ${IDLE_TIMEOUT}s; exiting"
        break
      fi
    else
      idle=0
    fi
    sleep 1
  fi
done

wait
