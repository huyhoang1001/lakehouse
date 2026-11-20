#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# LocalStack init hook — provisions the Day 3 lakehouse control rows.
#
# LocalStack runs every script in /etc/localstack/init/ready.d/ in name order,
# so this fires after 02-day2.sh: the Day 1 bucket/tables and the Day 2
# orchestration control plane already exist. Every step is idempotent (put-item
# overwrites), so restarts and re-runs are safe.
#
# Mirrors these Terraform resources (infra/modules/day3/):
#   s3.tf        -> the gold Delta prefix marker
#   dynamodb.tf  -> JOB_CONFIG rows 8–19 and MASTER_JOB_CONFIG rows ID=2 / ID=3
#
# Nothing is CREATED here: JOB_CONFIG is owned by Day 1 and MASTER_JOB_CONFIG by
# Day 2, exactly as in Terraform — Day 3 only adds rows.
#
# The two new control rows make the Day 3 master jobs runnable:
#   * JOB_CONFIG rows 8–19 give NT_Accelerate_Is_Allow_Running what it projects.
#     Delta rows are LAYER=LAKEHOUSE (routed to LAKEHOUSE_LOCATION); the Redshift
#     rows are LAYER=DW (routed to CATALOG_CON/PRESCRIPT/POSTSCRIPT/TEMP_FOLDER).
#   * MASTER_JOB_CONFIG ID=2 (LakeHouse) and ID=3 (RedshiftDW) carry the same
#     seed shape as the Day 2 ID=1 row, so NT_Accelerate_Read_Run_Type finds them.
# -----------------------------------------------------------------------------
set -euo pipefail

BUCKET="${BUCKET_NAME:-ntaccelerate-hoang-985176}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

GOLD="s3://$BUCKET/lake/gold/tickit/"
TEMP="s3://$BUCKET/temporary/"
SRC_DB="tickit"
CATALOG_CON="conRedshift_tickit"

log() { echo "[init-day3] $*"; }

awsl() { aws --endpoint-url http://localhost:4566 --region "$REGION" "$@"; }

# --- S3: gold Delta prefix marker --------------------------------------------
awsl s3api put-object --bucket "$BUCKET" --key "lake/gold/tickit/" >/dev/null
log "ensured s3://$BUCKET/lake/gold/tickit/ prefix marker"

# --- JOB_CONFIG rows 8–19 ----------------------------------------------------
# Two shapes, distinguished by LAYER. Both carry the full column superset that
# NT_Accelerate_Is_Allow_Running projects, so the scan never KeyErrors.

# Delta rows (LAYER = LAKEHOUSE), IDs 8–13. Columns not used by this layer are
# present but empty, matching infra/modules/day3/dynamodb.tf.
while IFS='|' read -r id job src tar; do
  [ -z "$id" ] && continue
  awsl dynamodb put-item --table-name NT_Accelerate_JOB_CONFIG --item "$(cat <<JSON
{
  "ID": {"N": "$id"},
  "JOB_NAME": {"S": "$job"},
  "LAYER": {"S": "LAKEHOUSE"},
  "MULTIPLE_RUN": {"S": "FALSE"},
  "REGION_NAME": {"S": "$REGION"},
  "SRC_DBNAME": {"S": "$SRC_DB"},
  "SRC_TBLNAME": {"S": "$src"},
  "TRG_DBNAME": {"S": "$GOLD"},
  "TRG_TBLNAME": {"S": "$tar"},
  "INCREMENTAL_LOAD": {"S": "False"},
  "CATALOG_CON": {"S": ""},
  "LAKEHOUSE_LOCATION": {"S": "$GOLD"},
  "PRESCRIPT": {"S": ""},
  "POSTSCRIPT": {"S": ""},
  "TEMP_FOLDER": {"S": ""}
}
JSON
)"
done <<'EOF'
8|jb_DW_Delta_Load_DateDim|date|DateDim
9|jb_DW_Delta_Load_VenueDim|venue|VenueDim
10|jb_DW_Delta_Load_CategoryDim|category|CategoryDim
11|jb_DW_Delta_Load_UserDim|users|UserDim
12|jb_DW_Delta_Load_EventDim|event|EventDim
13|jb_DW_Delta_Load_SalesFact|sales|SalesFact
EOF
log "seeded NT_Accelerate_JOB_CONFIG rows 8-13 (Delta / LAKEHOUSE)"

# Redshift rows (LAYER = DW), IDs 14–19. This layer routes to
# CATALOG_CON/PRESCRIPT/POSTSCRIPT/TEMP_FOLDER; the "drop table if exists" /
# "analyze" scripts mirror infra/modules/day3/dynamodb.tf.
while IFS='|' read -r id job src tar; do
  [ -z "$id" ] && continue
  awsl dynamodb put-item --table-name NT_Accelerate_JOB_CONFIG --item "$(cat <<JSON
{
  "ID": {"N": "$id"},
  "JOB_NAME": {"S": "$job"},
  "LAYER": {"S": "DW"},
  "MULTIPLE_RUN": {"S": "FALSE"},
  "REGION_NAME": {"S": "$REGION"},
  "SRC_DBNAME": {"S": "$SRC_DB"},
  "SRC_TBLNAME": {"S": "$src"},
  "TRG_DBNAME": {"S": "$SRC_DB"},
  "TRG_TBLNAME": {"S": "$tar"},
  "INCREMENTAL_LOAD": {"S": "False"},
  "CATALOG_CON": {"S": "$CATALOG_CON"},
  "LAKEHOUSE_LOCATION": {"S": ""},
  "PRESCRIPT": {"S": "drop table if exists $tar"},
  "POSTSCRIPT": {"S": "analyze $tar"},
  "TEMP_FOLDER": {"S": "$TEMP"}
}
JSON
)"
done <<'EOF'
14|jb_DW_Redshift_Load_DateDim|date|dim_date
15|jb_DW_Redshift_Load_VenueDim|venue|dim_venue
16|jb_DW_Redshift_Load_CategoryDim|category|dim_category
17|jb_DW_Redshift_Load_UserDim|users|dim_user
18|jb_DW_Redshift_Load_EventDim|event|dim_event
19|jb_DW_Redshift_Load_SalesFact|sales|fact_sales
EOF
log "seeded NT_Accelerate_JOB_CONFIG rows 14-19 (Redshift / DW)"

# --- MASTER_JOB_CONFIG rows ID=2 and ID=3 ------------------------------------
# Read first by NT_Accelerate_Read_Run_Type (each master job passes its own
# p_masterjob_id). Same seed shape as the Day 2 ID=1 row.
for id in 2 3; do
  awsl dynamodb put-item --table-name NT_Accelerate_MASTER_JOB_CONFIG --item "{
    \"ID\":{\"N\":\"$id\"},
    \"RUN_TYPE\":{\"S\":\"NEW\"},
    \"RERUN_DATE\":{\"S\":\"2024-01-01\"},
    \"BATCH_ID\":{\"N\":\"0\"},
    \"LAST_RUN_DATE\":{\"S\":\"2024-01-01\"},
    \"LAST_RUN_STATUS\":{\"S\":\"NEW\"}
  }"
done
log "seeded NT_Accelerate_MASTER_JOB_CONFIG (ID=2 LakeHouse, ID=3 RedshiftDW)"

log "ready: JOB_CONFIG +12 rows (8-19), MASTER_JOB_CONFIG +2 rows (2, 3)"
