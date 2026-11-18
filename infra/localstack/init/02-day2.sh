#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# LocalStack init hook — provisions the Day 2 orchestration control plane.
#
# LocalStack runs every script in /etc/localstack/init/ready.d/ in name order,
# so this fires after 01-provision.sh: the Day 1 bucket, its objects, the four
# Day 1 DynamoDB tables and the JDBC secret already exist. Every step here is
# idempotent, so restarts and re-runs are safe.
#
# Mirrors these Terraform resources (infra/modules/day2/):
#   dynamodb.tf  -> MASTER_JOB_CONFIG, Mail_Config, and the JOB_CONFIG superset
#   iam.tf       -> the two Day 2 roles
#   lambda.tf    -> the nine orchestration Lambda functions
#   ses.tf       -> the sender/receiver identities
#   sfn.tf       -> the three Step Functions master jobs
#
# ONE DELIBERATE DIFFERENCE from Terraform: LocalStack's free tier cannot run
# Glue, so every `glue:startJobRun.sync` state in the master jobs is rewritten
# to invoke a stub Lambda that records the JOB_LOG / JOB_STATUS rows a real Glue
# job would write (see day2/glue_stub.py and day2/transform_sfn.py). The
# Terraform path is untouched -- it deploys the Glue states verbatim.
# -----------------------------------------------------------------------------
set -euo pipefail

BUCKET="${BUCKET_NAME:-ntaccelerate-hoang-985176}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
LAMBDA_SRC="${DAY2_LAMBDA_DIR:-/opt/day2-lambda}"
SFN_SRC="${DAY2_SFN_DIR:-/opt/day2-sfn}"
HELPERS="${DAY2_HELPERS_DIR:-/opt/day2}"
MAIL_SENDER="${MAIL_SENDER:-elt.sender@example.com}"
MAIL_RECEIVERS="${MAIL_RECEIVERS:-elt.receiver@example.com}"
STUB_FUNCTION="NT_Accelerate_Local_Glue_Stub"

log() { echo "[init-day2] $*"; }

awsl() { aws --endpoint-url http://localhost:4566 --region "$REGION" "$@"; }

ACCOUNT="$(awsl sts get-caller-identity --query Account --output text)"

# --- DynamoDB control tables -------------------------------------------------
ddb_create() {
  local name="$1"; shift
  if awsl dynamodb describe-table --table-name "$name" >/dev/null 2>&1; then
    log "table $name already exists"
    return
  fi
  awsl dynamodb create-table --table-name "$name" "$@" >/dev/null
  awsl dynamodb wait table-exists --table-name "$name"
  log "created table $name"
}

ddb_create NT_Accelerate_MASTER_JOB_CONFIG \
  --attribute-definitions AttributeName=ID,AttributeType=N \
  --key-schema AttributeName=ID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Mail_Config's key is a STRING, not a number: NT_Accelerate_Send_Mail scans it
# with Key('ID').eq(str("1")). An N key would never match.
ddb_create NT_Accelerate_Mail_Config \
  --attribute-definitions AttributeName=ID,AttributeType=S \
  --key-schema AttributeName=ID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# --- DynamoDB seeds ----------------------------------------------------------
# The staging master row (ID=1) that every master job reads first.
awsl dynamodb put-item --table-name NT_Accelerate_MASTER_JOB_CONFIG --item '{
  "ID":{"N":"1"},
  "RUN_TYPE":{"S":"NEW"},
  "RERUN_DATE":{"S":"2024-01-01"},
  "BATCH_ID":{"N":"0"},
  "LAST_RUN_DATE":{"S":"2024-01-01"},
  "LAST_RUN_STATUS":{"S":"NEW"}
}'
log "seeded NT_Accelerate_MASTER_JOB_CONFIG (ID=1, RUN_TYPE=NEW)"

# RECEIVER is a List (L) of strings: Send_Mail hands it straight to
# ses:GetIdentityVerificationAttributes and then mutates it with .remove(),
# which needs a list rather than a string set.
python3 - "$MAIL_SENDER" "$MAIL_RECEIVERS" >/tmp/mail_config.json <<'PY'
import json, sys
sender = sys.argv[1]
receivers = [r.strip() for r in sys.argv[2].split(",") if r.strip()]
print(json.dumps({
    "ID": {"S": "1"},
    "SENDER": {"S": sender},
    "RECEIVER": {"L": [{"S": r} for r in receivers]},
}))
PY
awsl dynamodb put-item --table-name NT_Accelerate_Mail_Config --item file:///tmp/mail_config.json
log "seeded NT_Accelerate_Mail_Config (sender=$MAIL_SENDER, receivers=$MAIL_RECEIVERS)"

# --- JOB_CONFIG: rewrite the seven rows as the Day 2 superset ----------------
# Day 1 seeded these rows with the p_* columns only. Day 2 owns the same primary
# keys and rewrites each item with the full superset of columns
# (infra/modules/day2/dynamodb.tf). Without the extra columns
# NT_Accelerate_Is_Allow_Running raises KeyError on LAYER.
while IFS='|' read -r id job src tar incr; do
  [ -z "$id" ] && continue
  awsl dynamodb put-item --table-name NT_Accelerate_JOB_CONFIG --item "$(cat <<JSON
{
  "ID": {"N": "$id"},
  "JOB_NAME": {"S": "$job"},
  "p_src_tableName": {"S": "$src"},
  "p_tar_tablename": {"S": "$tar"},
  "p_is_incremental_load": {"S": "$incr"},
  "p_region": {"S": "$REGION"},
  "p_src_databaseName": {"S": "tickit"},
  "p_tar_databaseName": {"S": "s3://$BUCKET/lake/bronze/tickit/"},
  "p_catalog_conn": {"S": "conRDS_tickit"},
  "LAYER": {"S": "STAGING"},
  "MULTIPLE_RUN": {"S": "FALSE"},
  "CATALOG_CON": {"S": "conRDS_tickit"},
  "LAKEHOUSE_LOCATION": {"S": ""},
  "POSTSCRIPT": {"S": ""},
  "PRESCRIPT": {"S": ""},
  "TEMP_FOLDER": {"S": ""},
  "INCREMENTAL_LOAD": {"S": "$incr"},
  "REGION_NAME": {"S": "$REGION"},
  "SRC_DBNAME": {"S": "tickit"},
  "SRC_TBLNAME": {"S": "$src"},
  "TRG_DBNAME": {"S": "s3://$BUCKET/lake/bronze/tickit/"},
  "TRG_TBLNAME": {"S": "$tar"}
}
JSON
)"
done <<'EOF'
1|jb_Stg_Extract_Category|tickit_dbo_category|category|False
2|jb_Stg_Extract_Date|tickit_dbo_date|date|False
3|jb_Stg_Extract_Event|tickit_dbo_event|event|False
4|jb_Stg_Extract_Listing|tickit_dbo_listing|listing|False
5|jb_Stg_Extract_Users|tickit_dbo_users|users|False
6|jb_Stg_Extract_Venue|tickit_dbo_venue|venue|False
7|jb_Stg_Extract_Sales|tickit_dbo_sales|sales|True
EOF
log "extended NT_Accelerate_JOB_CONFIG with the Day 2 columns"

# --- IAM roles ---------------------------------------------------------------
# LocalStack does not enforce IAM by default, but the roles keep the local
# topology identical to the Terraform one (and keep lambda:CreateFunction happy).
iam_role() {
  local name="$1" service="$2"
  if awsl iam get-role --role-name "$name" >/dev/null 2>&1; then
    return
  fi
  awsl iam create-role --role-name "$name" --assume-role-policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"$service"},"Action":"sts:AssumeRole"}]}
JSON
)" >/dev/null
  log "created role $name"
}

iam_role NT_Accelerate_LambdaRole lambda.amazonaws.com
iam_role NT_Accelerate_StepFunctionsRole states.amazonaws.com

# --- SES identities ----------------------------------------------------------
# Send_Mail drops every recipient that is not verified, and LocalStack's SES
# rejects unverified senders/recipients, so both are verified here. Non-fatal:
# SES is only used by the final "Send mail" states.
for address in "$MAIL_SENDER" ${MAIL_RECEIVERS//,/ }; do
  [ -z "$address" ] && continue
  if awsl ses verify-email-identity --email-address "$address" >/dev/null 2>&1; then
    log "verified SES identity $address"
  else
    log "WARN: could not verify SES identity $address (SES unavailable?)"
  fi
done

# --- Lambda functions --------------------------------------------------------
lambda_names=(
  NT_Accelerate_Read_Run_Type
  NT_Accelerate_Check_Job_Status
  NT_Accelerate_Truncate_Job_Status
  NT_Accelerate_Is_Allow_Running
  NT_Accelerate_Check_Job_ReRun
  NT_Accelerate_Update_Job_Status
  NT_Accelerate_Update_MasterJob_Status
  NT_Accelerate_Check_Staging_Master_Job_Status
  NT_Accelerate_Send_Mail
)

# The container has python3 but no `zip` binary, so package with zipfile.
zip_one() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, zipfile
src, entry, out = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.write(src, f"{entry}.py")
PY
}

# LocalStack's new Lambda provider creates/updates functions ASYNCHRONOUSLY: a
# freshly deployed function sits in State=Pending until it becomes Active, and
# invoking it meanwhile fails with Lambda.ResourceConflictException (409). Block
# until it is Active so the first state-machine run cannot hit that.
wait_lambda_active() {
  local name="$1" state i
  # 90 x 2s = 180s: the very first function on a cold machine also pulls the
  # python3.9 base image, which can take well over a minute.
  for i in $(seq 1 90); do
    state="$(awsl lambda get-function --function-name "$name" \
      --query 'Configuration.State' --output text 2>/dev/null || true)"
    case "$state" in
      Active|None|"") return 0 ;;
      Failed) log "ERROR: Lambda $name failed to activate"; return 1 ;;
    esac
    sleep 2
  done
  log "WARN: Lambda $name still '$state' after waiting; continuing"
}

deploy_lambda() {
  local name="$1" src="$2" entry="$3"
  local zip="/tmp/${name}.zip"
  zip_one "$src" "$entry" "$zip"
  if awsl lambda get-function --function-name "$name" >/dev/null 2>&1; then
    awsl lambda update-function-code --function-name "$name" --zip-file "fileb://$zip" >/dev/null
    log "updated Lambda $name"
  else
    awsl lambda create-function \
      --function-name "$name" \
      --runtime python3.9 \
      --handler "${entry}.lambda_handler" \
      --role "arn:aws:iam::${ACCOUNT}:role/NT_Accelerate_LambdaRole" \
      --timeout 60 \
      --zip-file "fileb://$zip" >/dev/null
    log "created Lambda $name"
  fi
  wait_lambda_active "$name"
}

for name in "${lambda_names[@]}"; do
  deploy_lambda "$name" "$LAMBDA_SRC/${name}.py" "$name"
done

# The local Glue stand-in -- not part of the Terraform deployment.
deploy_lambda "$STUB_FUNCTION" "$HELPERS/glue_stub.py" "glue_stub"

# --- Step Functions master jobs ----------------------------------------------
# Map each function to the ARN LocalStack actually assigned it, so the rewritten
# definitions point at the real local functions rather than the lab's account.
arns_file=/tmp/day2_lambda_arns.json
{
  printf '{'
  sep=""
  for name in "${lambda_names[@]}"; do
    arn="$(awsl lambda get-function --function-name "$name" --query Configuration.FunctionArn --output text)"
    printf '%s"%s":"%s"' "$sep" "$name" "$arn"
    sep=","
  done
  printf '}'
} >"$arns_file"

stub_arn="$(awsl lambda get-function --function-name "$STUB_FUNCTION" --query Configuration.FunctionArn --output text)"

create_state_machine() {
  local name="$1" def_file="$2" out existing
  out="/tmp/${name}.json"
  python3 "$HELPERS/transform_sfn.py" "$SFN_SRC/$def_file" "$out" "$stub_arn" "$arns_file"

  existing="$(awsl stepfunctions list-state-machines \
    --query "stateMachines[?name=='$name'].stateMachineArn" --output text)"
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    awsl stepfunctions update-state-machine \
      --state-machine-arn "$existing" --definition "file://$out" >/dev/null
    log "updated state machine $name"
  else
    awsl stepfunctions create-state-machine \
      --name "$name" \
      --definition "file://$out" \
      --role-arn "arn:aws:iam::${ACCOUNT}:role/NT_Accelerate_StepFunctionsRole" >/dev/null
    log "created state machine $name"
  fi
}

create_state_machine NT_Accelerate_Datalake_Master_Job   "Edit NT_Accelerate_Datalake_Master_Job.json"
create_state_machine NT_Accelerate_LakeHouse_Master_Job  "Edit NT_Accelerate_LakeHouse_Master_Job.json"
create_state_machine NT_Accelerate_RedshiftDW_Master_Job "Edit NT_Accelerate_RedshiftDW_Master_Job.json"

log "ready: 2 Day 2 tables, 10 Lambdas (9 + stub), 3 state machines"
