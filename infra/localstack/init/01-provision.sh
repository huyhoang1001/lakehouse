#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# LocalStack init hook — provisions the local AWS resources the Glue jobs use.
#
# LocalStack runs everything in /etc/localstack/init/ready.d/ automatically once
# the API is up, so this fires on every `docker compose up`. Every step is
# idempotent, so restarts and re-runs are safe.
#
# Mirrors these Terraform resources (infra/modules/day1/):
#   s3.tf        -> the bucket, the 8 Glue scripts, the libraries, the raw files
#   dynamodb.tf  -> the 4 control tables + the JOB_CONFIG / watermark seeds
#   secrets.tf   -> the JDBC credentials secret
#
# This replaces running Terraform against LocalStack, which is why the local
# path needs no *_override.tf files.
# -----------------------------------------------------------------------------
set -euo pipefail

BUCKET="${BUCKET_NAME:-ntaccelerate-hoang-985176}"
ASSETS="${ASSETS_DIR:-/opt/assets}"
PASSWORD="${LOCAL_SQL_PASSWORD:-MyPass123!}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log() { echo "[init] $*"; }

# Talk to the local edge endpoint directly (the dummy credentials the container
# is started with satisfy the CLI).
awsl() { aws --endpoint-url http://localhost:4566 --region "$REGION" "$@"; }

# --- S3 bucket + objects -----------------------------------------------------
if awsl s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "bucket $BUCKET already exists"
else
  awsl s3 mb "s3://$BUCKET"
  log "created bucket $BUCKET"
fi

# Glue scripts, libraries and raw landing files (same keys as s3.tf).
awsl s3 sync "$ASSETS/Glue script" "s3://$BUCKET/glue_script/" \
  --exclude "*" --include "jb_Stg_Extract_*.py" --only-show-errors
awsl s3 cp "$ASSETS/S3/library/Genericlib.zip" "s3://$BUCKET/library/Genericlib.zip" --only-show-errors
awsl s3 cp "$ASSETS/S3/library/openpyxl-3.0.10.tar.gz" "s3://$BUCKET/library/openpyxl-3.0.10.tar.gz" --only-show-errors
awsl s3 cp "$ASSETS/S3/raw/csv/SalesEvent.csv" "s3://$BUCKET/raw/csv/SalesEvent.csv" --only-show-errors
awsl s3 cp "$ASSETS/S3/raw/excel/SalesEvent.xlsx" "s3://$BUCKET/raw/excel/SalesEvent.xlsx" --only-show-errors
awsl s3 cp "$ASSETS/S3/raw/json/user.json" "s3://$BUCKET/raw/json/user.json" --only-show-errors
awsl s3 cp "$ASSETS/S3/raw/xml/customer.xml" "s3://$BUCKET/raw/xml/customer.xml" --only-show-errors

# Zero-byte prefix markers (cosmetic, matches the Terraform uploads).
for prefix in "lake/bronze/tickit/" "sparkHistoryLogs/" "temporary/"; do
  awsl s3api put-object --bucket "$BUCKET" --key "$prefix" >/dev/null
done
log "uploaded scripts, libraries and raw files to s3://$BUCKET"

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

# Table names/spellings match Genericlib.py exactly -- do NOT "fix" the typos.
ddb_create NT_Accelerate_JOB_CONFIG \
  --attribute-definitions AttributeName=ID,AttributeType=N \
  --key-schema AttributeName=ID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
ddb_create NT_Accelerate_JOB_LOG \
  --attribute-definitions AttributeName=ID,AttributeType=S \
  --key-schema AttributeName=ID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
ddb_create NT_Accelarate_JOB_STATUS \
  --attribute-definitions AttributeName=JOB_NAME,AttributeType=S \
  --key-schema AttributeName=JOB_NAME,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
ddb_create NT_Acccelarate_WATERMARKTABLE \
  --attribute-definitions AttributeName=ID,AttributeType=N AttributeName=JOB_NAME,AttributeType=S \
  --key-schema AttributeName=ID,KeyType=HASH AttributeName=JOB_NAME,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

# --- DynamoDB seeds ----------------------------------------------------------
TAR_BASE="s3://$BUCKET/lake/bronze/tickit/"

while IFS='|' read -r id job src tar incr; do
  [ -z "$id" ] && continue
  awsl dynamodb put-item --table-name NT_Accelerate_JOB_CONFIG --item "{
    \"ID\":{\"N\":\"$id\"},
    \"JOB_NAME\":{\"S\":\"$job\"},
    \"p_src_tableName\":{\"S\":\"$src\"},
    \"p_tar_tablename\":{\"S\":\"$tar\"},
    \"p_is_incremental_load\":{\"S\":\"$incr\"},
    \"p_region\":{\"S\":\"$REGION\"},
    \"p_src_databaseName\":{\"S\":\"tickit\"},
    \"p_tar_databaseName\":{\"S\":\"$TAR_BASE\"},
    \"p_catalog_conn\":{\"S\":\"conRDS_tickit\"}
  }"
done <<'EOF'
1|jb_Stg_Extract_Category|tickit_dbo_category|category|False
2|jb_Stg_Extract_Date|tickit_dbo_date|date|False
3|jb_Stg_Extract_Event|tickit_dbo_event|event|False
4|jb_Stg_Extract_Listing|tickit_dbo_listing|listing|False
5|jb_Stg_Extract_Users|tickit_dbo_users|users|False
6|jb_Stg_Extract_Venue|tickit_dbo_venue|venue|False
7|jb_Stg_Extract_Sales|tickit_dbo_sales|sales|True
EOF
log "seeded NT_Accelerate_JOB_CONFIG"

awsl dynamodb put-item --table-name NT_Acccelarate_WATERMARKTABLE --item '{
  "ID":{"N":"0"},
  "JOB_NAME":{"S":"jb_Stg_Extract_Sales"},
  "COLUMN_NAMES":{"L":[{"S":"saletime"}]},
  "DATA_TYPES":{"L":[{"S":"STRING"}]},
  "DATA_VALUES":{"L":[{"S":"2008-12-31 12:58:19"}]},
  "QUERY_STRING":{"S":"select sellername, buyername, eventid, dateid, qtysold, pricepaid, commission, saletime from dbo.sales where "}
}'
log "seeded NT_Acccelarate_WATERMARKTABLE"

# --- Secrets Manager: JDBC credentials --------------------------------------
# Mirrors the cloud secret (RDS master user "admin" @ localhost:1433). The Glue
# runtime rewrites the host/user to the local container (sitecustomize.py).
SECRET_NAME="SQLSource_Database_Connection_Info"
SECRET_JSON=$(python3 -c '
import json, sys
print(json.dumps({
    "db_username": "admin",
    "db_password": sys.argv[1],
    "db_url": "jdbc:sqlserver://localhost:1433;databaseName=tickit",
    "driver_name": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
}))
' "$PASSWORD")

if awsl secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  awsl secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "$SECRET_JSON" >/dev/null
  log "updated secret $SECRET_NAME"
else
  awsl secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$SECRET_JSON" >/dev/null
  log "created secret $SECRET_NAME"
fi

log "ready: bucket=$BUCKET, 4 tables, secret=$SECRET_NAME"
