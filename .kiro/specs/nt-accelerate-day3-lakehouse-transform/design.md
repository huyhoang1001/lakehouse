# Design Document: NT Accelerate Day 3 — Lakehouse Transform (Delta Lake + Redshift)

## Overview

Day 3 adds the transform layer that closes the medallion loop: bronze Parquet (Day 1) → Delta Lake silver/gold and Amazon Redshift warehouse (Day 3), driven by the two data-warehouse master jobs that Day 2 already deploys.

The design keeps the layering honest:

- **Day 2 owns the orchestrator.** The three state machines (`NT_Accelerate_Datalake_Master_Job`, `NT_Accelerate_LakeHouse_Master_Job`, `NT_Accelerate_RedshiftDW_Master_Job`) are already deployed by `infra/modules/day2/sfn.tf`. Day 3 does **not** re-deploy or edit them. `NT_Accelerate_LakeHouse_Master_Job` and `NT_Accelerate_RedshiftDW_Master_Job` already reference the Day 3 Glue **job names** and the Lambda functions; Day 3 simply provides the jobs and the control-table rows those state machines need.
- **Day 3 owns the jobs and the targets.** A new `infra/modules/day3/` module creates the twelve `jb_DW_*` Glue jobs, the Delta storage + runtime jar, the Redshift warehouse + connection + credentials, and the `JOB_CONFIG` / `MASTER_JOB_CONFIG` seed rows.

Everything is Terraform HCL. The two transform Glue scripts are the only new application code; they are authored to satisfy the exact argument contract the master jobs pass (see Assumptions).

---

## Architecture

```
                              infra/day3/ (Terraform module)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                                                                                │
  │  ┌─────────────────────────────┐        ┌──────────────────────────────────┐   │
  │  │ S3 (Day 1 bucket)           │        │ Glue Data Catalog + Connections  │   │
  │  │  lake/bronze/tickit/...      │        │  conRedshift_tickit (JDBC)       │   │
  │  │  lake/gold/tickit/  ← new    │        │  (reuses conRDS_tickit)          │   │
  │  │  library/delta-spark_2.13-4.1.0.jar ← new                                │   │
  │  │  temporary/                  │        └──────────────────────────────────┘   │
  │  └──────────────┬───────────────┘                                              │
  │                 │ read                                                         │
  │                 ▼                                                              │
  │  ┌──────────────────────────────────────────────────────────────────────────┐ │
  │  │ Glue jobs (12)                                                           │ │
  │  │  Delta:    jb_DW_Delta_Load_{DateDim,VenueDim,CategoryDim,UserDim,       │ │
  │  │                                  EventDim,SalesFact}                     │ │
  │  │  Redshift: jb_DW_Redshift_Load_{DateDim,VenueDim,CategoryDim,UserDim,    │ │
  │  │                                  EventDim,SalesFact}                     │ │
  │  └──────────────┬───────────────────────────────┬──────────────────────────┘ │
  │                 │ write Delta                   │ COPY                      │
  │                 ▼                               ▼                            │
  │         s3://.../lake/gold/tickit/      ┌───────────────────────────┐        │
  │         (silver + gold Delta tables)    │ Amazon Redshift (tickit)  │        │
  │                                          └───────────────────────────┘        │
  │                                                                                │
  │  ┌──────────────────────────────────────────────────────────────────────────┐ │
  │  │ DynamoDB control tables (Day 1 / Day 2 tables, Day 3 seed rows)          │ │
  │  │  NT_Accelerate_JOB_CONFIG      ← +12 Day 3 rows                          │ │
  │  │  NT_Accelerate_MASTER_JOB_CONFIG ← +ID=2 (LakeHouse), ID=3 (RedshiftDW)  │ │
  │  │  NT_Accelarate_JOB_STATUS / NT_Accelerate_JOB_LOG ← written by jobs      │ │
  │  └──────────────────────────────────────────────────────────────────────────┘ │
  │                                                                                │
  │  Secrets Manager: redshift connection info    IAM: Glue role (extended)        │
  └──────────────────────────────────────────────────────────────────────────────┘
                 ▲ startExecution                        │ glue:startJobRun.sync
                 │                                       │
  ┌──────────────┴───────────────────────────────────────┴──────────────────────┐
  │ infra/modules/day2 (unchanged) — orchestrator                               │
  │  Staging Master Job (ID=1) → LakeHouse Master Job (ID=2) → Redshift (ID=3) │
  │  Lambdas: Read_Run_Type · Is_Allow_Running · Check_Staging_Master_Job_Status│
  │           Update_Job_Status · Update_MasterJob_Status · Truncate · Send_Mail│
  └─────────────────────────────────────────────────────────────────────────────┘
```

### Master Job Flow (LakeHouse `ID=2` / RedshiftDW `ID=3`)

```
StartAt: Read run_type from MASTER JOB CONFIG table   (p_masterjob_id = 2 | 3)
    │
    ▼
Choice: flag == true?
    ├── false → Fail: "Stop because of not configure yet"
    └── true  →
            Choice: run_type == NEW or RERUN?
            ├── RERUN → Parallel
            └── NEW   →
                    Lambda: Check_Staging_Master_Job_Status(p_run_date)
                        │
                        ▼
                    Choice: staging ran today with SUCCEEDED?
                    ├── false → Fail: "Staging master job not running yet"
                    └── true  →
                            Lambda: Check_Job_Status
                                │
                                ▼
                            Choice: FailedJobExisting?
                            ├── true  → Update_MasterJob(FAILED) → Fail
                            └── false → Truncate_Job_Status → Parallel
                                │
                                ▼
                    Parallel (4 dim branches: Date, Venue, Category, User)
                        each branch:
                          Is_Allow_Running → is_ran?
                            Yes → Update_Job_Status(SUCCEEDED)
                            No  → Glue startJobRun.sync(<jb_DW_*_Dim>)
                        Catch States.ALL → Update Master Job Failed → Send mail
                                │
                                ▼ (parallel complete)
                    Λ Check Dim Event → (Update SUCCEEDED | startJobRun.sync EventDim)
                                │
                                ▼
                    Λ Check Fact Sales → startJobRun.sync SalesFact
                                │
                                ▼
                    Update_MasterJob_Status(SUCCEEDED) → Send mail → End
```

Note the two asymmetries in the shipped definitions (deployed verbatim, not "fixed"): the **dim** branches run at most once via `Is_Allow_Running`, while the **EventDim** and **SalesFact** states call `startJobRun.sync` on the returned branch without an `is_ran` gate on the run path, and the **SalesFact** branch is sequential (not parallel) because the fact table depends on the dimensions.

---

## Components and Interfaces

### 3.1 Terraform Module: `infra/modules/day3/`

| File | Purpose |
|------|---------|
| `versions.tf` | Required providers (aws ≥ 5.x) |
| `variables.tf` | Inputs: `aws_region`, `bucket_name`, `bucket_arn`, `glue_database_name`, `glue_role_name`, `glue_role_arn`, `dynamodb_table_arns`, `enable_redshift`, `redshift_*`, `source_artifacts_dir`, `tags` |
| `locals.tf` | Table names (intentional-typo comments), Day 3 job list, gold/ bronze S3 paths, `delta_jar` key, redshift identifiers |
| `data.tf` | `data.aws_caller_identity`, `data.aws_region`, default VPC lookups |
| `s3.tf` | Gold prefix object, delta jar upload, temporary prefix |
| `glue_jobs.tf` | 12× `aws_glue_job` (Delta + Redshift) |
| `glue.tf` | `conRedshift_tickit` connection |
| `redshift.tf` | cluster, subnet group, SG (gated by `enable_redshift`) |
| `secrets.tf` | Redshift secret + version |
| `iam.tf` | Extend the Glue role (S3 gold write, secret read, catalog) |
| `dynamodb.tf` | 12 JOB_CONFIG rows + 2 MASTER_JOB_CONFIG rows |
| `outputs.tf` | Job names, delta location, redshift endpoint/connection, seeded row ids |

### 3.2 Glue Job Argument Contracts

The master jobs pass the following keys. The default arguments for each job must include every key so a manual run also works.

| Argument | Delta_Load_Job | Redshift_Load_Job | Source in master job |
|----------|:--------------:|:-----------------:|----------------------|
| `--p_batch_id` | ✓ | ✓ | `$.result.Payload.batch_id` |
| `--p_job_name` | ✓ | ✓ | `$.JobInfo.Payload.var_job_name` |
| `--p_region` | ✓ | ✓ | `$.JobInfo.Payload.var_region` |
| `--p_run_date` | ✓ | ✓ | `$.result.Payload.run_date` |
| `--p_src_databaseName` | ✓ | ✓ | `$.JobInfo.Payload.var_src_db` |
| `--p_src_tableName` | ✓ | ✓ | `$.JobInfo.Payload.var_scr_table` |
| `--p_tar_databaseName` | ✓ | ✓ | `$.JobInfo.Payload.var_trg_db` |
| `--p_tar_tablename` | ✓ | ✓ | `$.JobInfo.Payload.var_trg_table` |
| `--p_lakehouse_location` | ✓ | — | `$.JobInfo.Payload.var_lakehouse_location` |
| `--p_catalog_con` | — | ✓ | `$.JobInfo.Payload.var_catalog_con` |
| `--p_prescript` | — | ✓ | `$.JobInfo.Payload.var_prescript` |
| `--p_postscript` | — | ✓ | `$.JobInfo.Payload.var_postscript` |
| `--p_redshift_temp` | — | ✓ | `$.JobInfo.Payload.var_tempfolder` |
| `--extra-jars` | ✓ (`delta_jar`) | — | Terraform default arg |
| `--enable-glue-datacatalog` | ✓ | ✓ | Terraform default arg |

### 3.3 Day 3 Job Inventory

| Glue job | SRC (bronze table) | TRG | LAYER |
|----------|--------------------|-----|-------|
| `jb_DW_Delta_Load_DateDim` | `date` | `DateDim` (Delta) | `LAKEHOUSE` |
| `jb_DW_Delta_Load_VenueDim` | `venue` | `VenueDim` | `LAKEHOUSE` |
| `jb_DW_Delta_Load_CategoryDim` | `category` | `CategoryDim` | `LAKEHOUSE` |
| `jb_DW_Delta_Load_UserDim` | `users` | `UserDim` | `LAKEHOUSE` |
| `jb_DW_Delta_Load_EventDim` | `event` | `EventDim` | `LAKEHOUSE` |
| `jb_DW_Delta_Load_SalesFact` | `sales` | `SalesFact` | `LAKEHOUSE` |
| `jb_DW_Redshift_Load_DateDim` | `date` | `dim_date` | `DW` |
| `jb_DW_Redshift_Load_VenueDim` | `venue` | `dim_venue` | `DW` |
| `jb_DW_Redshift_Load_CategoryDim` | `category` | `dim_category` | `DW` |
| `jb_DW_Redshift_Load_UserDim` | `users` | `dim_user` | `DW` |
| `jb_DW_Redshift_Load_EventDim` | `event` | `dim_event` | `DW` |
| `jb_DW_Redshift_Load_SalesFact` | `sales` | `fact_sales` | `DW` |

---

## Data Models

### JOB_CONFIG — Day 3 rows

`NT_Accelerate_JOB_CONFIG` (PK `ID` N). Day 1 / Day 2 own IDs 1–7. Day 3 adds one row per job (e.g. IDs 8–19). Each row is a **superset** so `NT_Accelerate_Is_Allow_Running` never hits a missing key.

| Attribute | Type | Delta row value | Redshift row value |
|-----------|------|-----------------|--------------------|
| `ID` | N | 8–13 | 14–19 |
| `JOB_NAME` | S | `jb_DW_Delta_Load_*` | `jb_DW_Redshift_Load_*` |
| `LAYER` | S | `LAKEHOUSE` | `DW` |
| `MULTIPLE_RUN` | S | `FALSE` | `FALSE` |
| `REGION_NAME` | S | `us-east-1` | `us-east-1` |
| `SRC_DBNAME` | S | `tickit` | `tickit` |
| `SRC_TBLNAME` | S | bronze table (`sales`, …) | bronze table (`sales`, …) |
| `TRG_DBNAME` | S | `s3://<bucket>/lake/gold/tickit/` | `tickit` |
| `TRG_TBLNAME` | S | `DateDim`, … | `dim_date`, … |
| `INCREMENTAL_LOAD` | S | `False` | `False` |
| `CATALOG_CON` | S | `""` | `conRedshift_tickit` |
| `LAKEHOUSE_LOCATION` | S | `s3://<bucket>/lake/gold/tickit/` | `""` |
| `PRESCRIPT` | S | `""` | prescript SQL / S3 URI |
| `POSTSCRIPT` | S | `""` | postscript SQL / S3 URI |
| `TEMP_FOLDER` | S | `""` | `s3://<bucket>/temporary/` |

Why the columns split by layer (verbatim from `NT_Accelerate_Is_Allow_Running`):

- `LAYER == "STAGING"` → clears `catalog_con`, uses `INCREMENTAL_LOAD`.
- `LAYER == "LAKEHOUSE"` → uses `LAKEHOUSE_LOCATION`, clears `catalog_con` and the prescript/postscript/temp fields.
- anything else (`DW`) → uses `CATALOG_CON`, `PRESCRIPT`, `POSTSCRIPT`, `TEMP_FOLDER`.

### MASTER_JOB_CONFIG — Day 3 rows

`NT_Accelerate_MASTER_JOB_CONFIG` (PK `ID` N). Day 2 owns ID=1 (Staging).

| ID | Master job | Seed |
|----|-----------|------|
| 2 | `NT_Accelerate_LakeHouse_Master_Job` | `RUN_TYPE=NEW, RERUN_DATE=2024-01-01, BATCH_ID=0, LAST_RUN_DATE=2024-01-01, LAST_RUN_STATUS=NEW` |
| 3 | `NT_Accelerate_RedshiftDW_Master_Job` | same shape |

`NT_Accelerate_Read_Run_Type` queries this table by `ID`, so a missing row makes the master job fail immediately at `Stop because of not configure yet`.

### Secrets Manager — Redshift

```
{
  "username": "<redshift master user>",
  "password": "<redshift master password>",
  "url": "jdbc:redshift://<endpoint>:5439/tickit",
  "driver": "com.amazon.redshift.jdbc42.Driver"
}
```

### S3 layout (Day 1 bucket)

```
lake/bronze/tickit/<table>/<run_date>/      (Day 1 — read by Day 3)
lake/gold/tickit/<DeltaTable>/              (Day 3 — Delta)
library/delta-spark_2.13-4.1.0.jar          (Day 3 — Delta runtime)
temporary/                                  (Redshift COPY staging)
```

---

## Error Handling

### Master job failures

- Every Lambda `Task` state keeps the Day 2 `Retry` block (`MaxAttempts: 6`, `IntervalSeconds: 2`, `BackoffRate: 2`). Deployed verbatim.
- The `Parallel` state has `Catch: States.ALL → Update Master Job Failed for Job Failed → Send mail`. A single failing dimension job fails the whole parallel block, updates `MASTER_JOB_CONFIG` with `FAILED`, and still sends the status email.
- The `Fail` terminal state is reached when (a) the `MASTER_JOB_CONFIG` row does not exist, (b) `RUN_TYPE=NEW` with unresolved `FAILED` rows in `JOB_STATUS`, or (c) the Day 2 staging gate reports the Staging_Master_Job has not succeeded for the run date.

### Glue job failures

- A Glue job that fails is reported to Step Functions by `glue:startJobRun.sync`, which raises the error into the `Parallel` `Catch`.
- The Glue scripts write `FAILED` to `NT_Accelarate_JOB_STATUS` with an `ERROR_MSG` and append a `JOB_LOG` row, so a later `RERUN` picks the job up (`Is_Allow_Running` deletes the `FAILED` row and returns `is_ran=No`).

### Delta runtime / Redshift connectivity

- **Delta jar ABI:** the provided `delta-spark_2.13-4.1.0.jar` is built for Scala 2.13 / Spark 4.x, while Glue 3.0/4.0 ship Spark 3.x / Scala 2.12. The Glue version for the Delta jobs must be chosen so the jar's Spark/Scala ABI matches, or a Glue-compatible Delta jar must be substituted. This is the highest-risk item in the spec and is called out in Assumptions.
- **Redshift reachability:** the Redshift SG must allow 5439 from the Glue connection SG and the connection must sit in a subnet that routes to the cluster. A failure here surfaces as a JDBC timeout, not a permission error.
- **Secrets:** the Glue role reads the Redshift secret at runtime; a missing grant surfaces as `AccessDeniedException` on `secretsmanager:GetSecretValue`.

### Terraform apply ordering

- Glue jobs reference the Day 1 bucket and connections; `depends_on` the delta jar upload so `--extra-jars` points at an existing object.
- The Day 3 `aws_dynamodb_table_item` rows for `JOB_CONFIG` target the Day 1 table (resolved by name), and the `MASTER_JOB_CONFIG` rows target the Day 2 table.
- Redshift-dependent resources are gated behind `enable_redshift` with `count`, so a Redshift-free apply still creates the Delta side.

---

## Testing Strategy

This feature is Infrastructure as Code (Terraform) plus two authored Glue scripts. Property-based testing is not appropriate: Terraform resources are declarative, and the transform scripts are I/O-bound Spark jobs. The strategy is example-based validation plus post-apply smoke tests.

### Unit / example tests (Terraform)

`terraform validate` / `terraform plan`:

- All twelve `aws_glue_job` resources appear with the exact `jb_DW_*` names.
- `NT_Accelerate_JOB_CONFIG` plan shows twelve new items; `JOB_NAME` values match the state-machine `JobName`s.
- `NT_Accelerate_MASTER_JOB_CONFIG` plan shows rows `ID=2` and `ID=3` and leaves `ID=1` untouched.
- `enable_redshift=false` produces zero Redshift resources; `enable_redshift=true` produces a cluster, subnet group, SG, secret, and connection.
- Every Day 3 Delta job's default arguments include `--extra-jars` pointing at `library/delta-spark_2.13-4.1.0.jar`.
- No misspelled table name is "corrected" (grep the module for the two exact typo names).

### Integration tests (post-apply smoke)

Performed manually or in CI after `terraform apply`:

1. **Control-table resolution:** invoke `NT_Accelerate_Read_Run_Type` with `{"p_masterjob_id": 2}` and `{"p_masterjob_id": 3}`; assert `flag=true` and `run_type=NEW`.
2. **Argument resolution:** invoke `NT_Accelerate_Is_Allow_Running` with a Day 3 Delta job and a Day 3 Redshift job; assert the response's `var_lakehouse_location` is the gold path (Delta) and `var_catalog_con` / `var_tempfolder` are populated (Redshift).
3. **Staging gate:** start `NT_Accelerate_LakeHouse_Master_Job` before the Staging_Master_Job has succeeded and assert the execution reaches the `Staging master job not running yet` Fail state.
4. **Delta write:** run the Staging_Master_Job NEW for a date, then LakeHouse_Master_Job NEW; assert `lake/gold/tickit/<table>/_delta_log/` exists for each of the six tables and `JOB_LOG`/`JOB_STATUS` show `SUCCEEDED`.
5. **Redshift load:** run RedshiftDW_Master_Job NEW; assert the six tables exist in the `tickit` database with expected row counts.
6. **Rerun:** set `RUN_TYPE=RERUN` with a matching `RERUN_DATE` and a seeded `FAILED` row; assert only the failed job reruns.
