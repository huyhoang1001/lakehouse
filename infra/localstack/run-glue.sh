#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Local Glue runner (free, no AWS account).
#
# Runs an AWS Glue ETL script inside the official AWS Glue Docker image -- the
# same Glue/Spark runtime AWS uses -- wired to LocalStack for S3 + DynamoDB and
# to the local SQL Server container for the source database. The whole stack is
# described by docker-compose.yml, so this script only supplies the command;
# `docker compose run` brings the stack up first if it isn't running.
#
# How the wiring works:
#   * The image runs a *login* shell so .bashrc supplies SPARK_HOME, PYTHONPATH
#     and PyGlue.zip (needed for `import awsglue`).
#   * `s3://` is remapped to the Hadoop S3A filesystem pointed at LocalStack
#     (spark.hadoop.fs.s3.impl), so Glue's glueparquet writer lands in LocalStack.
#   * boto3 in this image (1.24) predates AWS_ENDPOINT_URL, so a sitecustomize
#     shim (day1/) redirects DynamoDB + Secrets Manager calls to LocalStack.
#   * The proprietary `glueparquet` writer is unavailable outside the managed
#     Glue service, so day1/local_glue_runner.py maps glueparquet -> parquet
#     (the job scripts themselves are not modified).
#   * The Glue Data Catalog is unavailable locally, so the same runner maps
#     create_dynamic_frame.from_catalog(...) to a direct JDBC read of the local
#     SQL Server container (see docs/local-development.md).
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
#   # incremental job (reads credentials from Secrets Manager + watermark):
#   ./run-glue.sh jb_Stg_Extract_Sales.py \
#       --JOB_NAME local-sales --p_job_name jb_Stg_Extract_Sales \
#       --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
#       --p_is_incremental_load True --p_catalog_conn conRDS_tickit \
#       --p_src_databaseName tickit --p_src_tableName tickit_dbo_sales \
#       --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
#       --p_tar_tablename sales
#
# Everything else (image, mounts, endpoints, credentials) is configured in
# docker-compose.yml.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT="${1:?usage: run-glue.sh <script.py> [glue args...]}"
shift || true
GLUE_ARGS="$*"

# --rm: discard the job container. -T: no TTY (works when output is piped).
# The container runs the Glue job with a login shell so the image's .bashrc
# sets SPARK_HOME / PYTHONPATH / PyGlue.zip.
docker compose -f "$HERE/docker-compose.yml" --profile tools run --rm -T \
  --entrypoint /bin/bash \
  glue -lc "
    set -e
    pip install --quiet --disable-pip-version-check openpyxl==3.0.10
    cd /home/glue_user/workspace
    exec /home/glue_user/spark/bin/spark-submit \
      --master 'local[*]' \
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
      /home/glue_user/workspace/glue_script/${SCRIPT} ${GLUE_ARGS}
  "
