# NT Accelerate Day 1 Ingestion — Tasks

Implementation tasks for the spec `nt-accelerate-day1-ingestion`. Numbering follows `requirements.md` sections. Mark dependencies in parentheses. Optional tasks are flagged.

## 1. Project scaffolding (refs Req 1–12)
- [x] 1.1 Create `infra/` layout: `versions.tf`, `variables.tf`, `locals.tf`, `providers.tf`
- [x] 1.2 Pin AWS provider `~> 5.0`, region `us-east-1`; configure from `AWS_*` env / shared credentials
- [x] 1.3 Define `variables.tf` (bucket_name, db creds, run_date, batch_id, enable_flatfile_job, source_artifacts_dir, tags) per design Interfaces
- [x] 1.4 Define `outputs.tf` placeholders (bucket, rds_endpoint, job names, table names, secret)

## 2. S3 bucket and artifact uploads (refs Req 1)
- [x] 2.1 `aws_s3_bucket` with `var.bucket_name` (depends 1.1)
- [x] 2.2 Enable versioning, block public access, SSE-S3 encryption
- [x] 2.3 Upload the 8 Glue `.py` scripts to `glue_script/` via `aws_s3_object` (source = `source_artifacts_dir`)
- [x] 2.4 Zip `Genericlib.py` into `Genericlib.zip` (`archive_file`) and upload to `library/` with `openpyxl-3.0.10.tar.gz`
- [x] 2.5 Upload raw samples (csv/xlsx/json/xml) to `raw/<type>/` (depends 2.1)
- [x] 2.6 Create zero-byte prefix objects: `lake/bronze/tickit/`, `sparkHistoryLogs/`, `temporary/`

## 3. IAM Glue role (refs Req 2)
- [x] 3.1 `aws_iam_role` `NT_Accelerate_GlueRole` with `glue.amazonaws.com` trust (depends 2.1)
- [x] 3.2 Attach `AWSGlueServiceRole` managed policy
- [x] 3.3 Inline `aws_iam_role_policy`: S3 on `var.bucket_name` only, DynamoDB on the 4 table ARNs only, `secretsmanager:GetSecretValue` on the secret ARN (created in §5 — use the planned ARN), CloudWatch Logs

## 4. Networking and RDS (refs Req 3)
- [x] 4.1 Data-source default VPC + subnets; create `aws_security_group` `sg_rds` and `sg_glue` (depends 1.1)
- [x] 4.2 RDS SG ingress rule: TCP 1433 from `sg_glue`
- [x] 4.3 `aws_db_subnet_group` using default subnets
- [x] 4.4 `aws_db_instance`: engine `sqlserver-ex`, `db.t3.micro`, 20 GB gp2, publicly accessible, creds from vars, `sg_rds` (depends 4.1, 4.3)

## 5. Secrets Manager (refs Req 5)
- [x] 5.1 `aws_secretsmanager_secret` `SQLSource_Database_Connection_Info` (depends 4.4)
- [x] 5.2 `aws_secretsmanager_secret_version` with JSON `db_username`, `db_password`, `db_url` (JDBC `databaseName=tickit`), `driver_name` (depends 5.1)
- [x] 5.3 Wire the secret ARN into the Glue role policy from §3.3

## 6. RDS seeding (refs Req 4)
- [x] 6.1 `null_resource` `db_seed` with `local-exec`: `sqlcmd -S <endpoint> -U .. -P .. -i tickit_script.sql` (depends 4.4)
- [x] 6.2 Guard with `triggers = sha256(tickit_script.sql)`; prepend a `sys.tables` existence check so it is idempotent
- [x] 6.3 Document the `sqlcmd` prerequisite (SQL Server tools) in a README (optional)

## 7. DynamoDB control tables (refs Req 6)
- [x] 7.1 Create `NT_Accelerate_JOB_CONFIG` (PK `ID` N) — exact name (depends 1.1)
- [x] 7.2 Create `NT_Accelerate_JOB_LOG` (PK `ID` S)
- [x] 7.3 Create `NT_Accelarate_JOB_STATUS` (PK `JOB_NAME` S) — note spelling
- [x] 7.4 Create `NT_Acccelarate_WATERMARKTABLE` (PK `ID` N, SK `JOB_NAME` S) — note spelling
- [x] 7.5 Seed `JOB_CONFIG` rows (one per job) via `aws_dynamodb_table_item` or `null_resource` `aws dynamodb put-item`
- [x] 7.6 Seed Sales `WATERMARKTABLE` row (saletime, `2008-12-31 12:58:19`, QUERY_STRING) (depends 7.4)
- [x] 7.7 Reference the 4 table ARNs in the Glue role policy from §3.3

## 8. Glue catalog, connection, crawler (refs Req 7)
- [x] 8.1 `aws_glue_catalog_database` `tickit` (depends 3.1)
- [x] 8.2 `aws_glue_connection` `conRDS_tickit` (JDBC, `sg_glue`, subnet, JDBC URL from RDS endpoint) (depends 4.4)
- [x] 8.3 `aws_glue_crawler` `NT_Accelerate_cwl_RDSTickit` (JDBC target `tickit`, role, target DB `tickit`) (depends 8.1, 3.1, 4.4)

## 9. Glue extraction jobs (refs Req 8, 9)
- [x] 9.1 Create `aws_glue_job` `jb_Stg_Extract_Category` (full load, 10 params, G.1X x2, Glue 3.0, bookmark, library, temp/log paths) (depends 2.3, 5.2, 8.2, 3.1)
- [x] 9.2 Create `aws_glue_job` `jb_Stg_Extract_Date` (full load) (depends 9.1 patterns)
- [x] 9.3 Create `aws_glue_job` `jb_Stg_Extract_Event` (full load)
- [x] 9.4 Create `aws_glue_job` `jb_Stg_Extract_Listing` (full load)
- [x] 9.5 Create `aws_glue_job` `jb_Stg_Extract_Users` (full load)
- [x] 9.6 Create `aws_glue_job` `jb_Stg_Extract_Venue` (full load)
- [x] 9.7 Create `aws_glue_job` `jb_Stg_Extract_Sales` with `p_is_incremental_load=True` (depends 7.6, 5.2, 8.2)
- [x] 9.8 (optional) Create `aws_glue_job` `jb_Stg_Extract_ExcelFile` gated by `var.enable_flatfile_job` (depends 2.5)

## 10. Run and verify (refs Req 11)
- [~] 10.1 `terraform apply`; capture outputs (depends all §2–§9)
- [~] 10.2 Run crawler: `aws glue start-crawler --name NT_Accelerate_cwl_RDSTickit` (depends 8.3)
- [~] 10.3 Verify in Console: Glue → Databases → tickit shows 7 `tickit_dbo_*` tables
- [~] 10.4 Trigger the 6 full-load jobs; verify Parquet under `lake/bronze/tickit/<table>/<date>/`
- [~] 10.5 Verify Console: DynamoDB `JOB_LOG` = SUCCEEDED, `JOB_STATUS` current
- [~] 10.6 Trigger `jb_Stg_Extract_Sales`; verify `WATERMARKTABLE.DATA_VALUES` advanced

## 11. Teardown and cost control (refs Req 12)
- [~] 11.1 Add a `null_resource` to empty the bucket before destroy (`aws s3 rm --recursive`) (optional but recommended)
- [~] 11.2 `aws_db_instance` with `skip_final_snapshot=true` so destroy is clean
- [~] 11.3 Document low-cost idle steps: stop RDS (`aws rds stop-db-instance`), delete secret (depends 5.1)
- [~] 11.4 `terraform destroy` smoke test in sandbox

## Verification runbook (refs Req 11) — Console-only checks
1. S3 → `ntaccelerate` → `lake/bronze/tickit/<table>/<date>/` contains `.parquet`.
2. Glue → Data Catalog → Databases → `tickit` → Tables: 7 `tickit_dbo_*`.
3. Glue → Connections → `conRDS_tickit` → Test connection = OK.
4. Glue → Jobs: 7 (or 8) jobs present with correct script/library/params.
5. DynamoDB → `NT_Accelerate_JOB_LOG`: SUCCEEDED rows per job. `NT_Accelarate_JOB_STATUS`: latest status. `NT_Acccelarate_WATERMARKTABLE`: Sales row with advanced `DATA_VALUES`.
6. Secrets Manager → `SQLSource_Database_Connection_Info` present.
7. IAM → Roles → `NT_Accelerate_GlueRole` with scoped inline policy.
