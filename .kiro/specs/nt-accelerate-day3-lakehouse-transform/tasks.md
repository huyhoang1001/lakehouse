# Implementation Plan: NT Accelerate Day 3 — Lakehouse Transform (Delta Lake + Redshift)

## Overview

This plan builds the Day 3 transform layer on top of the Day 1 ingestion and Day 2 orchestration stacks. All infrastructure lives in a new Terraform module `infra/modules/day3/` that receives Day 1 and Day 2 outputs as inputs and never modifies their files.

The Day 2 module already deploys the three master state machines (`NT_Accelerate_Datalake_Master_Job`, `NT_Accelerate_LakeHouse_Master_Job`, `NT_Accelerate_RedshiftDW_Master_Job`) — this plan does not re-deploy or edit them. Day 3 supplies the twelve Glue jobs, the Delta storage + runtime, the Redshift warehouse + connection + credentials, and the `JOB_CONFIG` / `MASTER_JOB_CONFIG` seed rows those state machines consume.

Tasks are ordered: module + IAM scaffolding → storage (Delta) → Glue jobs (Delta, then Redshift) → Redshift warehouse + connection + secrets → control-table seed rows → wiring + outputs → checkpoint.

---

## Tasks

- [ ] 1. Set up Terraform module scaffolding for `infra/modules/day3/`
  - Create directory `infra/modules/day3/`
  - Write `versions.tf` with required providers (aws ≥ 5.x)
  - Write `variables.tf` with input variables: `aws_region`, `bucket_name`, `bucket_arn`, `glue_database_name`, `glue_role_name`, `glue_role_arn`, `dynamodb_table_arns`, `enable_redshift`, `redshift_database_name`, `redshift_master_username`, `redshift_master_password`, `redshift_node_type`, `redshift_number_of_nodes`, `source_artifacts_dir`, `tags`
  - Write `locals.tf` defining table names (with comments marking intentional typos), the twelve Day 3 job names, bronze/gold/temporary S3 paths, and the delta_jar S3 key
  - Write `data.tf` with `data.aws_caller_identity`, `data.aws_region`, and default VPC / subnet lookups for the Redshift subnet group
  - Wire `module "day3"` into `infra/main.tf`, passing `module.day1.*` and `module.day2.*` outputs as inputs
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

- [ ] 2. Extend IAM for Delta and Redshift
  - [ ] 2.1 Extend the Glue role with S3 gold-write permissions
    - Grant `s3:GetObject`/`s3:ListBucket` on `lake/bronze/*` and `temporary/*`, and `s3:PutObject`/`s3:DeleteObject` on `lake/gold/*` and `temporary/*`
    - _Requirements: 9.1_
  - [ ] 2.2 Grant the Glue role the Redshift secret read and Glue catalog permissions
    - Grant `secretsmanager:GetSecretValue` on the Redshift secret ARN
    - Grant `glue:GetDatabase`, `glue:GetTable`, `glue:CreateTable`, `glue:UpdateTable`, `glue:BatchCreatePartition`, `glue:BatchDeletePartition`
    - _Requirements: 9.2, 9.3, 9.4_

- [ ] 3. Provision Delta Lake storage and runtime
  - [ ] 3.1 Create the gold and temporary S3 prefixes
    - Add zero-byte `aws_s3_object` markers for `lake/gold/tickit/` and `temporary/`
    - _Requirements: 2.1_
  - [ ] 3.2 Upload the Delta runtime jar
    - `aws_s3_object` uploading `instruction/day1/delta-spark_2.13-4.1.0.jar.txt` to `library/delta-spark_2.13-4.1.0.jar`
    - Use `etag = filemd5(...)` so a jar change re-uploads on the next apply
    - Expose the jar S3 URI via a local for the Delta jobs
    - _Requirements: 2.2, 2.3, 2.4_

- [ ] 4. Create the Redshift warehouse, connection, and credentials
  - [ ] 4.1 Create the Redshift subnet group and security group
    - Subnet group over the default VPC subnets; SG allowing 5439 from the Glue connection SG
    - Gate with `count = var.enable_redshift ? 1 : 0`
    - _Requirements: 4.2, 4.4_
  - [ ] 4.2 Create the Redshift cluster
    - `aws_redshift_cluster` with `db_name = var.redshift_database_name` (`tickit`), `node_type = var.redshift_node_type`, `number_of_nodes = var.redshift_number_of_nodes`, `skip_final_snapshot = true`
    - _Requirements: 4.1, 4.3_
  - [ ] 4.3 Create the Redshift Glue connection
    - `aws_glue_connection` type `JDBC` named `conRedshift_tickit` with URL `jdbc:redshift://<endpoint>:5439/tickit` and the subnet/SG connection properties
    - _Requirements: 6.1_
  - [ ] 4.4 Create the Redshift secret
    - `aws_secretsmanager_secret` + `_version` with `{username, password, url, driver}`
    - _Requirements: 6.2, 6.4_

- [ ] 5. Create the Delta load Glue jobs
  - [ ] 5.1 Author the Delta load Glue script
    - Script reads bronze Parquet for `--p_src_tableName` and writes/merges a Delta table at `<--p_lakehouse_location>/<--p_tar_tablename>`
    - Accepts the full Day 3 argument contract; logs to `NT_Accelerate_JOB_LOG` and writes `NT_Accelarate_JOB_STATUS`
    - _Requirements: 3.4, 3.6_
  - [ ] 5.2 Upload the Delta script to S3
    - `aws_s3_object` from `source_artifacts_dir` (or the module's `scripts/`) to `glue_script/jb_DW_Delta_Load.py`
    - _Requirements: 3.2_
  - [ ] 5.3 Add the six `aws_glue_job` resources
    - Names exactly `jb_DW_Delta_Load_{DateDim,VenueDim,CategoryDim,UserDim,EventDim,SalesFact}`
    - `default_arguments` with `--p_batch_id`, `--p_job_name`, `--p_lakehouse_location`, `--p_region`, `--p_run_date`, `--p_src_databaseName`, `--p_src_tableName`, `--p_tar_databaseName`, `--p_tar_tablename`, `--extra-jars = <delta_jar uri>`, `--enable-glue-datacatalog`
    - `glue_version`, `worker_type`, `number_of_workers`, `max_retries`, `timeout`, `max_concurrent_runs` per Day 1 conventions
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

- [ ] 6. Create the Redshift load Glue jobs
  - [ ] 6.1 Author the Redshift load Glue script
    - Script reads bronze Parquet for `--p_src_tableName` and loads `--p_tar_databaseName` / `--p_tar_tablename`, using `--p_prescript`, `--p_postscript`, and `--p_redshift_temp`
    - Accepts the full Day 3 argument contract; logs to `NT_Accelerate_JOB_LOG` and writes `NT_Accelarate_JOB_STATUS`
    - _Requirements: 5.2, 5.4, 5.5_
  - [ ] 6.2 Upload the Redshift script to S3
    - `aws_s3_object` to `glue_script/jb_DW_Redshift_Load.py`
    - _Requirements: 5.2_
  - [ ] 6.3 Add the six `aws_glue_job` resources
    - Names exactly `jb_DW_Redshift_Load_{DateDim,VenueDim,CategoryDim,UserDim,EventDim,SalesFact}`
    - `default_arguments` with the nine common args plus `--p_catalog_con`, `--p_prescript`, `--p_postscript`, `--p_redshift_temp`, `--enable-glue-datacatalog`
    - Attach `conRedshift_tickit`
    - _Requirements: 5.1, 5.2, 5.3_

- [ ] 7. Seed the Day 3 control-table rows
  - [ ] 7.1 Add twelve `JOB_CONFIG` rows
    - One `aws_dynamodb_table_item` per Day 3 job in `NT_Accelerate_JOB_CONFIG`, IDs that do not collide with 1–7
    - Delta rows: `LAYER=LAKEHOUSE`, `LAKEHOUSE_LOCATION=s3://<bucket>/lake/gold/tickit/`, other DW fields empty
    - Redshift rows: `LAYER=DW`, `CATALOG_CON=conRedshift_tickit`, `PRESCRIPT`/`POSTSCRIPT`/`TEMP_FOLDER` set, `LAKEHOUSE_LOCATION` empty
    - All rows carry the full superset of columns read by `NT_Accelerate_Is_Allow_Running`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_
  - [ ] 7.2 Add `MASTER_JOB_CONFIG` rows `ID=2` and `ID=3`
    - `RUN_TYPE=NEW, RERUN_DATE=2024-01-01, BATCH_ID=0, LAST_RUN_DATE=2024-01-01, LAST_RUN_STATUS=NEW`
    - Do not touch `ID=1`
    - _Requirements: 8.1, 8.2, 8.3_

- [ ] 8. Write module outputs and run-order docs
  - Create `infra/modules/day3/outputs.tf` exposing:
    - Day 3 Glue job names (Delta + Redshift)
    - Delta gold S3 location
    - Redshift endpoint and connection name (null when `enable_redshift=false`)
    - Day 3 `JOB_CONFIG` row IDs
  - Document the required run order (Staging → LakeHouse → RedshiftDW) and the staging gate in the module README
  - _Requirements: 10.1, 10.2, 10.3, 13.1_

- [ ] 9. Checkpoint — Validate Terraform and test the Day 3 run
  - Run `terraform init` and `terraform validate` in `infra/`; assert zero errors
  - Run `terraform plan`; assert twelve `aws_glue_job` resources, twelve `JOB_CONFIG` items, and rows `ID=2`/`ID=3` appear
  - Run `terraform apply -auto-approve` in a sandbox account
  - Invoke `NT_Accelerate_Read_Run_Type` with `{"p_masterjob_id": 2}` and `{"p_masterjob_id": 3}`; assert `flag=true`, `run_type=NEW`
  - Invoke `NT_Accelerate_Is_Allow_Running` for one Delta and one Redshift job; assert the returned parameters match the seeded row
  - Run Staging_Master_Job NEW, then LakeHouse_Master_Job NEW; assert `lake/gold/tickit/<table>/_delta_log/` exists for all six tables
  - Run RedshiftDW_Master_Job NEW; assert the six tables exist in the `tickit` database
  - Assert `JOB_LOG` / `JOB_STATUS` show `SUCCEEDED` for all twelve jobs and no unresolved `FAILED` rows
  - Ensure all tests pass, ask the user if questions arise.

---

## Notes

- The Day 2 module already deploys all three master state machines; this plan must **not** edit `infra/modules/day2/sfn.tf`. The LakeHouse and RedshiftDW jobs it references are the ones created in tasks 5 and 6.
- The Day 3 Glue transform scripts are **not** part of the provided lab artifacts. Tasks 5.1 and 6.1 author them to satisfy the exact argument contract the master jobs pass (see `design.md` §3.2). If the original lab scripts become available, drop them into `source_artifacts_dir` and deploy verbatim instead.
- **Highest risk:** the provided `delta-spark_2.13-4.1.0.jar` is a Scala 2.13 / Spark 4.x build, while Glue 3.0/4.0 ship Spark 3.x / Scala 2.12. Pick a Glue version + Delta jar combination whose Spark/Scala ABI matches, or the Delta jobs will fail at runtime with a `NoSuchMethodError`/`ClassNotFoundException`. Confirm before task 9.
- Tables `NT_Accelarate_JOB_STATUS` and `NT_Acccelarate_WATERMARKTABLE` keep their intentional misspellings; comments in `locals.tf` mark them as deliberate.
- The Redshift cluster bills hourly. Keep `enable_redshift=false` (or `terraform destroy`) when the lab is idle. `skip_final_snapshot=true` keeps teardown clean.
- The `MASTER_JOB_CONFIG` `ID=2`/`ID=3` rows use the same `NEW`/`RERUN` semantics as `ID=1`; each master job increments its own `BATCH_ID`.
- Day 3 `JOB_CONFIG` rows use `MULTIPLE_RUN=FALSE` (run once per day) and rely on the Day 2 `Is_Allow_Running` single-run de-dup against `NT_Accelerate_JOB_LOG`.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2.1"] },
    { "id": 1, "tasks": ["2.2", "3.1", "4.1"] },
    { "id": 2, "tasks": ["3.2", "4.2", "4.4"] },
    { "id": 3, "tasks": ["4.3", "5.1", "6.1"] },
    { "id": 4, "tasks": ["5.2", "6.2"] },
    { "id": 5, "tasks": ["5.3", "6.3", "7.1"] },
    { "id": 6, "tasks": ["7.2", "8"] },
    { "id": 7, "tasks": ["9"] }
  ]
}
```
