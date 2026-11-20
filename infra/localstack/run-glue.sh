#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Local Glue runner (free, no AWS account).
#
# Runs an AWS Glue ETL script inside the official AWS Glue Docker image -- the
# same Glue/Spark runtime AWS uses -- wired to LocalStack for S3 + DynamoDB, to
# the local SQL Server container for the source database, and to the local
# Postgres container for the Day 3 warehouse stand-in. The whole stack is
# described by docker-compose.yml, so this script only supplies the command;
# `docker compose run` brings the stack up first if it isn't running.
#
# How the wiring works:
#   * The image runs a *login* shell so .bashrc supplies SPARK_HOME, PYTHONPATH
#     and PyGlue.zip (needed for `import awsglue`).
#   * `s3://` is remapped to the Hadoop S3A filesystem pointed at LocalStack
#     (spark.hadoop.fs.s3.impl), so Glue's glueparquet writer -- and the Day 3
#     Delta writer -- land in LocalStack.
#   * boto3 in this image (1.24) predates AWS_ENDPOINT_URL, so a sitecustomize
#     shim (day1/) redirects DynamoDB + Secrets Manager calls to LocalStack.
#   * The proprietary `glueparquet` writer is unavailable outside the managed
#     Glue service, so day1/local_glue_runner.py maps glueparquet -> parquet
#     (the job scripts themselves are not modified).
#   * The Glue Data Catalog is unavailable locally, so the same runner maps
#     create_dynamic_frame.from_catalog(...) to a direct JDBC read of the local
#     SQL Server, and write_dynamic_frame.from_jdbc_conf(...) to a direct JDBC
#     write to the local Postgres (see docs/local-development.md).
#   * Day 3 Delta jobs get the Delta Spark session extension + catalog on the
#     classpath via --jars/--conf, using the JARs fetch-jars.sh downloads. The
#     Day 1 / Day 2 jobs are left untouched (no Delta config).
#
# Script lookup: the Day 1 jobs each have their own script, so <name>.py is
# found under glue_script/. The Day 3 jobs share two scripts, so the six
# jb_DW_Delta_Load_* jobs resolve to glue_script_dw/jb_DW_Delta_Load.py and the
# six jb_DW_Redshift_Load_* jobs to glue_script_dw/jb_DW_Redshift_Load.py --
# the same one-script-per-family layout the Terraform module deploys.
#
# Usage:
#   ./run-glue.sh jb_Stg_Extract_ExcelFile.py \
#       --JOB_NAME local-excel \
#       --p_job_name jb_Stg_Extract_ExcelFile \
#       --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
#       --p_src_databaseName /home/glue_user/workspace/raw/excel/ \
#       --p_src_tableName SalesEvent.xlsx \
#       --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
#       --p_tar_tablename salesevent
#
#   # full-load job (reads via the catalog -> JDBC bridge):
#   ./run-glue.sh jb_Stg_Extract_Venue.py \
#       --JOB_NAME local-venue --p_job_name jb_Stg_Extract_Venue \
#       --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
#       --p_is_incremental_load False --p_catalog_conn conRDS_tickit \
#       --p_src_databaseName tickit --p_src_tableName tickit_dbo_venue \
#       --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
#       --p_tar_tablename venue
#
#   # Day 3 Delta job (name is the job; the shared script is resolved for you):
#   ./run-glue.sh jb_DW_Delta_Load_DateDim.py \
#       --JOB_NAME jb_DW_Delta_Load_DateDim --p_job_name jb_DW_Delta_Load_DateDim \
#       --p_run_date 2026-11-20 --p_batch_id 1 --p_region us-east-1 \
#       --p_lakehouse_location s3://ntaccelerate-hoang-985176/lake/gold/tickit/ \
#       --p_src_databaseName tickit --p_src_tableName date \
#       --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/gold/tickit/ \
#       --p_tar_tablename DateDim
#
# Everything else (image, mounts, endpoints, credentials, the Postgres
# stand-in) is configured in docker-compose.yml.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT="${1:?usage: run-glue.sh <script.py> [glue args...]}"
shift || true
GLUE_ARGS="$*"

# Day 3 Delta jobs need the Delta runtime on the Spark classpath. Fetch the
# JARs (idempotent) and hand spark-submit the same session extension + catalog
# the Terraform module sets through the job's --conf/--extra-jars arguments.
DELTA_ARGS=""
case "$SCRIPT" in
  jb_DW_Delta_Load*.py)
    "$HERE/fetch-jars.sh"
    DELTA_ARGS="--jars /home/glue_user/workspace/jars/delta-core_2.12-2.3.0.jar,/home/glue_user/workspace/jars/delta-storage-2.3.0.jar --conf spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog"
    ;;
esac

# The openpyxl install is only needed by the Day 1 Excel job; skipping it for
# the table jobs keeps a Day 3 run (twelve Spark jobs) from paying for it.
EXTRA_PIP=""
if [ "$SCRIPT" = "jb_Stg_Extract_ExcelFile.py" ]; then
  EXTRA_PIP="pip install --quiet --disable-pip-version-check openpyxl==3.0.10"
fi

# --rm: discard the job container. -T: no TTY (works when output is piped).
# The container runs the Glue job with a login shell so the image's .bashrc
# sets SPARK_HOME / PYTHONPATH / PyGlue.zip.
docker compose -f "$HERE/docker-compose.yml" --profile tools run --rm -T \
  --entrypoint /bin/bash \
  glue -lc "
    set -e
    ${EXTRA_PIP}
    cd /home/glue_user/workspace
    SCRIPT_FILE='${SCRIPT}'
    if [ -f \"glue_script/\$SCRIPT_FILE\" ]; then
      SCRIPT_PATH=\"glue_script/\$SCRIPT_FILE\"
    elif [ -f \"glue_script_dw/\$SCRIPT_FILE\" ]; then
      SCRIPT_PATH=\"glue_script_dw/\$SCRIPT_FILE\"
    else
      case \"\$SCRIPT_FILE\" in
        jb_DW_Delta_Load_*.py)    SCRIPT_PATH=\"glue_script_dw/jb_DW_Delta_Load.py\" ;;
        jb_DW_Redshift_Load_*.py) SCRIPT_PATH=\"glue_script_dw/jb_DW_Redshift_Load.py\" ;;
        *)                        SCRIPT_PATH=\"glue_script/\$SCRIPT_FILE\" ;;
      esac
    fi
    echo \"[run-glue] script: \$SCRIPT_PATH\"
    exec /home/glue_user/spark/bin/spark-submit \
      --master 'local[*]' \
      ${DELTA_ARGS} \
      --conf spark.hadoop.fs.s3.impl=org.apache.hadoop.fs.s3a.S3AFileSystem \
      --conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem \
      --conf spark.hadoop.fs.s3a.endpoint=\${LOCALSTACK_ENDPOINT} \
      --conf spark.hadoop.fs.s3a.path.style.access=true \
      --conf spark.hadoop.fs.s3a.connection.ssl.enabled=false \
      --conf spark.hadoop.fs.s3a.access.key=test \
      --conf spark.hadoop.fs.s3a.secret.key=test \
      --conf spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider \
      --py-files /home/glue_user/workspace/library/Genericlib.zip \
      /home/glue_user/workspace/pylib/local_glue_runner.py \
      \$SCRIPT_PATH ${GLUE_ARGS}
  "
