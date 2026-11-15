# NT Accelerate Day 1 Ingestion — Design

## Context

This spec rebuilds the AWS TechCamp Day 1 lab as Terraform. The original lab was done by hand in the AWS Console; here every resource is provisioned by `terraform apply` and the Console is used only to verify. The provided Glue Python scripts and the `Genericlib.py` library are reused verbatim — Terraform uploads them to S3 and points `aws_glue_job` resources at them. We do **not** rewrite the extraction logic.

Region is pinned to `us-east-1` to match the lab's JDBC URL and watermark seed values.

## Goals / Non-Goals

**Goals**
- Provision S3, IAM, networking, RDS (SQL Server Express + seed), Secrets Manager, DynamoDB, and Glue (catalog, connection, crawler, 7 RDS jobs) via Terraform.
- Reuse the provided `.py` scripts and `Genericlib.py` unchanged.
- Make the stack idempotent, cheap to idle, and fully destroyable.
- Provide Console-only verification.

**Non-Goals**
- Day 2 orchestration (master job, Step Functions, Lambda, SES) — separate spec.
- Delta Lake / gold layer and Redshift migration — out of Day 1 scope.
- CI/CD pipeline wiring.
- Rewriting or improving the Glue extraction scripts.

## Architecture

```
                         ┌───────────────────────────────┐
                         │  Terraform  (infra/*.tf)        │
                         └───────────────┬───────────────┘
                                         │ apply
   ┌─────────────────────────────────────┴───────────────────────────────────┐
   │ us-east-1                                                                │
   │                                                                          │
   │  IAM: NT_Accelerate_GlueRole (Glue trust + S3/Dynamo/Secrets/Logs)        │
   │                                                                          │
   │  S3: ntaccelerate                                                        │
   │   ├── glue_script/*.py        ├── library/Genericlib.zip                 │
   │   ├── raw/{csv,excel,json,xml}├── lake/bronze/tickit/<table>/<date>/      │
   │   ├── sparkHistoryLogs/       └── temporary/                             │
   │                                                                          │
   │  Secrets Manager: SQLSource_Database_Connection_Info                     │
   │   {db_username, db_password, db_url, driver_name}                        │
   │                                                                          │
   │  DynamoDB (names match Genericlib.py EXACTLY, incl. typos):              │
   │   NT_Accelerate_JOB_CONFIG   NT_Accelerate_JOB_LOG                       │
   │   NT_Accelarate_JOB_STATUS   NT_Acccelarate_WATERMARKTABLE               │
   │                                                                          │
   │  RDS: SQL Server Express (db.t3.micro) ── SG allows 1433 from Glue SG ──┐│
   │   db: tickit  (seeded from tickit_script.sql)                            ││
   │                                                                          ││
   │  Glue:                                                                   ││
   │   DB "tickit" ─► Crawler (conRDS_tickit) ─► catalog tables tickit_dbo_*   ││
   │   Jobs (Spark, G.1X x2):                                                  ││
   │     Category/Date/Event/Listing/Users/Venue  = full  (from_catalog)      ││
   │     Sales                                       = incremental (JDBC+watermark)
   │     ExcelFile (optional)                       = flat-file (pandas)      ││
   └──────────────────────────────────────────────────────────────────────────┘│
                                 └──────────── Console verify only ────────────┘
```

## Data Flow

1. `apply` creates S3 and uploads scripts + library + raw samples + prefixes.
2. `apply` creates RDS; a `null_resource` seeds `tickit_script.sql` once via `sqlcmd`.
3. `apply` creates Secrets Manager secret and the four DynamoDB tables (with seeded rows).
4. `apply` creates the Glue catalog DB, JDBC connection, and crawler.
5. Operator runs the crawler (console or `aws glue start-crawler`) → catalog tables `tickit_dbo_<table>`.
6. Operator runs the 6 full-load jobs → each reads its catalog table and writes Snappy Parquet to `lake/bronze/tickit/<table>/<run_date>/`, logging to `JOB_LOG`/`JOB_STATUS`.
7. Operator runs `jb_Stg_Extract_Sales` → JDBC read with watermark predicate, Parquet append, watermark advanced in `WATERMARKTABLE`.
8. (Optional) `jb_Stg_Extract_ExcelFile` reads raw flat files and writes Parquet.
9. Console verifies steps 5–7 outputs.

## Interfaces

### Terraform inputs (`variables.tf`)
| Variable | Type | Purpose |
|---|---|---|
| `aws_region` | string | `us-east-1` (default) |
| `bucket_name` | string | S3 bucket name (must be globally unique) |
| `db_username` / `db_password` | string (sensitive) | RDS master creds |
| `db_instance_class` | string | `db.t3.micro` default |
| `db_allocated_storage` | number | 20 GB default |
| `enable_flatfile_job` | bool | toggle Req 10 (default false) |
| `run_date` | string | `p_run_date` value, e.g. `2024-01-01` |
| `batch_id` | number | `p_batch_id`, default 1 |
| `source_artifacts_dir` | string | local path to the provided Day 1 source |
| `tags` | map(string) | common tags |

### Terraform outputs (`outputs.tf`)
- `s3_bucket_name`
- `rds_endpoint` (JDBC URL form)
- `glue_job_names` (list)
- `glue_database_name`, `crawler_name`, `connection_name`
- `dynamodb_table_names` (map)
- `secret_arn`, `secret_name`

### Glue job parameter contract (the 10 `--p_*` the scripts read)
The scripts call `getResolvedOptions` for: `JOB_NAME, p_job_name, p_run_date, p_batch_id, p_region, p_is_incremental_load, p_catalog_conn, p_src_databaseName, p_src_tableName, p_tar_databaseName, p_tar_tablename`. (`jb_Stg_Extract_ExcelFile.py` uses a smaller subset: omits `p_is_incremental_load` and `p_catalog_conn`.)

## Data Models

### Secrets Manager secret payload (`SQLSource_Database_Connection_Info`)
```json
{ "db_username": "<rds user>", "db_password": "<rds pass>",
  "db_url": "jdbc:sqlserver://<rds_endpoint>:1433;databaseName=tickit",
  "driver_name": "com.microsoft.sqlserver.jdbc.SQLServerDriver" }
```
Note: the scripts pass `db_url` straight to Spark JDBC, so it must use `databaseName=` (the demo script form), not the doc's `database=` form.

### DynamoDB tables (exact names — typos are intentional, matching `Genericlib.py`)
| Table | Key schema | Purpose |
|---|---|---|
| `NT_Accelerate_JOB_CONFIG` | PK `ID` (N) | Per-job parameters (drives design; scripts currently read `--p_*` params, table is config source of truth) |
| `NT_Accelerate_JOB_LOG` | PK `ID` (S) | One row per run: batch_id, job_name, run_date, status, error_msg, start/end, src/trg counts |
| `NT_Accelarate_JOB_STATUS` | PK `JOB_NAME` (S) | Latest status per job |
| `NT_Acccelarate_WATERMARKTABLE` | PK `ID` (N), SK `JOB_NAME` (S) | Incremental watermark: COLUMN_NAMES, DATA_TYPES, DATA_VALUES, QUERY_STRING |

### Per-job parameter mapping (full-load jobs)
| Job | `p_src_tableName` | `p_tar_tablename` | `p_is_incremental_load` |
|---|---|---|---|
| jb_Stg_Extract_Category | tickit_dbo_category | category | False |
| jb_Stg_Extract_Date | tickit_dbo_date | date | False |
| jb_Stg_Extract_Event | tickit_dbo_event | event | False |
| jb_Stg_Extract_Listing | tickit_dbo_listing | listing | False |
| jb_Stg_Extract_Users | tickit_dbo_users | users | False |
| jb_Stg_Extract_Venue | tickit_dbo_venue | venue | False |
| jb_Stg_Extract_Sales | tickit_dbo_sales | sales | True (incremental) |

Common params: `p_region=us-east-1`, `p_batch_id=<var>`, `p_run_date=<var>`, `p_src_databaseName=tickit`, `p_tar_databaseName=s3://<bucket>/lake/bronze/tickit/`, `p_job_name=<job name>`, `p_catalog_conn=conRDS_tickit` (unused by full-load path but declared in the script's `getResolvedOptions`, so it must be supplied).

### Sales watermark seed (`WATERMARKTABLE`)
```
ID=0, JOB_NAME=jb_Stg_Extract_Sales,
COLUMN_NAMES=["saletime"], DATA_TYPES=["STRING"],
DATA_VALUES=["2008-12-31 12:58:19"],
QUERY_STRING="select sellername, buyername, eventid, dateid, qtysold, pricepaid, commission, saletime from dbo.sales where "
```

## Per-Requirement Design

- **Req 1 (S3):** `aws_s3_bucket` + `aws_s3_object` per artifact; `aws_s3_bucket_versioning`, `aws_s3_bucket_public_access_block`, `aws_s3_bucket_server_side_encryption_configuration`. Prefixes via zero-byte `aws_s3_object`.
- **Req 2 (IAM):** `aws_iam_role` (trust `glue.amazonaws.com`) + `aws_iam_role_policy` inline scoped to bucket/tables/secret/logs; attach `AWSGlueServiceRole` managed policy.
- **Req 3 (Network/RDS):** default VPC data sources; `aws_security_group` for RDS and for Glue connection; `aws_db_subnet_group`; `aws_db_instance` (sqlserver-ex, `db.t3.micro`, public access, SG). RDS stop = outside TF state; document `aws rds stop-db-instance`.
- **Req 4 (Seed):** `null_resource` with `local-exec` running `sqlcmd -S <endpoint> -U .. -P .. -i tickit_script.sql`, guarded by `triggers` (sha256 of the SQL file) so it runs once; skip if tables exist (query `sys.tables` first).
- **Req 5 (Secrets):** `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version`; glue role policy grants `secretsmanager:GetSecretValue` on the secret ARN.
- **Req 6 (DynamoDB):** four `aws_dynamodb_table` (PAY_PER_REQUEST) with the exact names above; seed via `aws_dynamodb_table_item` (or a `null_resource` with `aws dynamodb put-item` for list-typed attributes that TF's `table_item` handles awkwardly).
- **Req 7 (Catalog/Crawler):** `aws_glue_catalog_database`, `aws_glue_connection` (JDBC, with connection-properties subnet+SG), `aws_glue_crawler` (JDBC target, role, target DB `tickit`, include path `tickit`).
- **Req 8 (Full-load jobs):** `aws_glue_job` ×6, `command.script_location` = the uploaded S3 path, `default_arguments` with the 10 params, `glue_version=3.0`, `worker_type=G.1X`, `number_of_workers=2`, `max_retries=0`, `timeout=15`, `connections=["conRDS_tickit"]` (needed for JDBC reachability of the incremental path; harmless for catalog reads), `max_concurrent_runs=1`, `bookmark_option=Enable`.
- **Req 9 (Sales):** same `aws_glue_job` with `p_is_incremental_load=True`; relies on `WATERMARKTABLE` + secret; the script updates the watermark itself.
- **Req 10 (Flat file, optional):** `count = var.enable_flatfile_job ? 1 : 0` `aws_glue_job` using the Excel script; library path includes `openpyxl-3.0.10.tar.gz`.
- **Req 11 (Verify):** `outputs.tf`; a `verify.md` runbook in the spec lists the Console screens to check.
- **Req 12 (Teardown/cost):** `terraform destroy` empties the bucket first via a `null_resource` (`aws s3 rm --recursive`); RDS deletion via `aws_db_instance` `skip_final_snapshot=true`; secret and tables deleted with the stack.

## Error Handling

- **Glue↔RDS unreachable:** RDS SG must allow 1433 from the Glue connection SG; the connection's subnet must route to the RDS subnet. Verify with Glue "Test connection" (Console) — failures here are networking, not credentials.
- **Missing DynamoDB tables:** must use the exact `Genericlib.py` spellings; a name mismatch surfaces as `ResourceNotFoundException` mid-job.
- **Bucket name collision:** TF errors at apply; operator sets a unique `bucket_name`.
- **Seed re-run:** `null_resource` trigger guards re-seed; `sys.tables` check avoids duplicate INSERTs.
- **JDBC URL form:** must be `databaseName=tickit`; the doc's `database=tickit` form does not work with the provided script.
- **Job bookmark + date partitions:** full loads partition by run date; bookmark prevents re-read of source but output path includes today's date, so same-day reruns overwrite the same partition (acceptable for the lab).

## Testing / Verification Strategy

- **Static:** `terraform fmt -check`, `terraform validate`, `terraform plan` reviewed before apply.
- **Apply smoke test:** `apply` to a sandbox account; confirm all resources exist via Console (Req 11).
- **Crawler run:** `aws glue start-crawler`; confirm 7 `tickit_dbo_*` catalog tables.
- **Job runs:** trigger the 6 full-load jobs; confirm Parquet under `lake/bronze/tickit/<table>/<date>/` and SUCCEEDED rows in `JOB_LOG`.
- **Incremental run:** run Sales twice (after inserting a later-dated row) and confirm watermark advances in `WATERMARKTABLE`.
- **Destroy test:** `terraform destroy` cleanly removes everything; bucket emptied first.

## Key Gotchas

1. DynamoDB table names in `Genericlib.py` are misspelled (`NT_Accelarate_JOB_STATUS`, `NT_Acccelarate_WATERMARKTABLE`) — honor them exactly.
2. The scripts declare `p_catalog_conn` in `getResolvedOptions` even though the doc's parameter list omits it; supply it or the job fails to resolve args.
3. The Excel job's `df.applymap(str)` is deprecated in newer pandas; only relevant if `enable_flatfile_job=true`.
4. `tickit_script.sql` is ~245 MB of INSERTs; seeding is the one step that needs `sqlcmd` (or SSMS), not pure Terraform.
5. RDS SQL Server Express only runs on `db.t3.micro`/`small` instance classes; do not pick a larger class without changing the license model.
