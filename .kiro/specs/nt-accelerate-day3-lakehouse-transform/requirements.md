# Requirements Document

## Introduction

Day 3 of the NT Accelerate TechCamp lakehouse series completes the medallion pipeline by adding the transform layer that turns the Day 1 bronze data into silver and gold.

Day 1 extracts seven Tickit tables from RDS SQL Server into S3 bronze as Parquet using AWS Glue. Day 2 wraps those jobs in a master-job control system (Step Functions + Lambda + DynamoDB) and — already in scope for Day 2 — deploys all **three** master state machines: `NT_Accelerate_Datalake_Master_Job`, `NT_Accelerate_LakeHouse_Master_Job`, and `NT_Accelerate_RedshiftDW_Master_Job`. Day 3 gives the two data-warehouse master jobs something to run:

- `NT_Accelerate_LakeHouse_Master_Job` (master job `ID=2`) orchestrates six `jb_DW_Delta_Load_*` Spark jobs that read the bronze Parquet and write **Delta Lake** tables (silver/gold) back into S3.
- `NT_Accelerate_RedshiftDW_Master_Job` (master job `ID=3`) orchestrates six `jb_DW_Redshift_Load_*` Spark jobs that read the bronze Parquet and load an **Amazon Redshift** warehouse.

All infrastructure is provisioned with Terraform in a new `infra/modules/day3/` module that receives Day 1 and Day 2 outputs as input variables and never modifies Day 1 or Day 2 files.

> Scope note: the lab artifact set under `instruction/` ships the Day 1 Glue extraction scripts and the Day 2 Lambda / Step Functions definitions, but **not** the Day 3 transform scripts. The Day 3 Glue job scripts are therefore authored as part of this spec (Requirements 3 and 5). If the original lab scripts become available they replace the authored ones and are deployed verbatim.

## Glossary

- **Step_Functions**: AWS Step Functions, the managed state machine service orchestrating the master jobs.
- **Lambda**: AWS Lambda functions implementing the control-plane decisions (deployed in Day 2).
- **DynamoDB**: Amazon DynamoDB, the control-plane store for job configuration, run state, and mail configuration.
- **Glue_Job**: An AWS Glue Spark ETL job.
- **Staging_Job**: One of the seven Day 1 extraction jobs `jb_Stg_Extract_*` that write bronze Parquet under `s3://<bucket>/lake/bronze/tickit/`.
- **Delta_Load_Job**: One of the six Day 3 jobs `jb_DW_Delta_Load_*` that read bronze Parquet and write Delta Lake tables.
- **Redshift_Load_Job**: One of the six Day 3 jobs `jb_DW_Redshift_Load_*` that read bronze Parquet and load Amazon Redshift.
- **Staging_Master_Job**: The state machine `NT_Accelerate_Datalake_Master_Job` (master job `ID=1`) that orchestrates the seven Day 1 extraction jobs.
- **LakeHouse_Master_Job**: The state machine `NT_Accelerate_LakeHouse_Master_Job` (master job `ID=2`) that orchestrates the six Delta_Load_Jobs.
- **RedshiftDW_Master_Job**: The state machine `NT_Accelerate_RedshiftDW_Master_Job` (master job `ID=3`) that orchestrates the six Redshift_Load_Jobs.
- **Bronze**: The raw Parquet layer written by Day 1 under `lake/bronze/`.
- **Silver**: The cleaned / conformed Delta Lake layer.
- **Gold**: The curated Delta Lake layer and the Redshift warehouse served to analytics.
- **Delta_Lake**: The open table format (`io.delta`) written by the Delta_Load_Jobs.
- **Redshift**: Amazon Redshift, the columnar warehouse loaded by the Redshift_Load_Jobs.
- **MASTER_JOB_CONFIG**: DynamoDB table `NT_Accelerate_MASTER_JOB_CONFIG` (PK: `ID` N), created in Day 2, holding run type, rerun date, batch ID, and last run status per master job. Day 3 seeds rows `ID=2` and `ID=3`.
- **JOB_CONFIG**: DynamoDB table `NT_Accelerate_JOB_CONFIG` (PK: `ID` N), created in Day 1 and extended in Day 2. Day 3 adds one row per Day 3 Glue job.
- **JOB_STATUS**: DynamoDB table `NT_Accelarate_JOB_STATUS` (PK: `JOB_NAME` S) — intentional misspelling, must not be corrected.
- **JOB_LOG**: DynamoDB table `NT_Accelerate_JOB_LOG` storing historical run records per job.
- **WATERMARKTABLE**: DynamoDB table `NT_Acccelarate_WATERMARKTABLE` — intentional misspelling, must not be corrected.
- **Mail_Config**: DynamoDB table `NT_Accelerate_Mail_Config` (PK: `ID` S), created in Day 2.
- **LAYER**: A `JOB_CONFIG` routing column. `NT_Accelerate_Is_Allow_Running` treats `STAGING`, `LAKEHOUSE`, and anything else (`DW`) differently when it assembles Glue job arguments.
- **RUN_TYPE**: The execution mode stored in MASTER_JOB_CONFIG: `NEW` (fresh daily run) or `RERUN` (selective retry).
- **BATCH_ID**: A monotonically increasing integer in MASTER_JOB_CONFIG incremented on each NEW run.
- **MULTIPLE_RUN**: A `JOB_CONFIG` flag. When `FALSE`, a Glue job runs at most once per day.
- **SES**: Amazon Simple Email Service, used by the Day 2 `Send_Mail` Lambda for the run-status email.
- **Terraform_Module**: A self-contained Terraform configuration; `infra/modules/day3/` is the Day 3 module.
- **delta_jar**: The Delta runtime jar `delta-spark_2.13-4.1.0.jar` uploaded to S3 and attached to the Delta jobs.

---

## Requirements

### Requirement 1: Terraform Module Structure

**User Story:** As a data platform engineer, I want all Day 3 infrastructure defined in a separate Terraform module `infra/modules/day3/`, so that Day 1 and Day 2 resources are never modified and each layer can be managed independently.

#### Acceptance Criteria

1. THE Terraform_Module SHALL define all Day 3 resources under the directory path `infra/modules/day3/`.
2. THE Terraform_Module SHALL receive the Day 1 and Day 2 outputs it needs (S3 bucket name and ARN, Glue database name, Glue role ARN, DynamoDB table ARNs, Day 2 master-job state machine ARNs) as **input variables** passed by the root module, and SHALL NOT use `terraform_remote_state`.
3. THE Terraform_Module SHALL NOT modify, import, or destroy any file under `infra/modules/day1/` or `infra/modules/day2/`.
4. THE Terraform_Module SHALL accept `aws_region`, `bucket_name`, `bucket_arn`, `glue_database_name`, `glue_role_arn`, `glue_role_name`, `dynamodb_table_arns`, `enable_redshift`, `redshift_*`, and `tags` as input variables with documented descriptions.
5. THE root module `infra/main.tf` SHALL instantiate `module "day3"` after `module "day2"` and pass the Day 1 and Day 2 outputs through.
6. WHEN `terraform apply` is run from `infra/`, THE Terraform_Module SHALL provision all Day 3 resources without manual console intervention.

---

### Requirement 2: Delta Lake Storage and Runtime

**User Story:** As a data platform engineer, I want the Delta Lake gold location and the Delta runtime jar provisioned in S3, so that the Delta_Load_Jobs can write Delta tables without manual upload steps.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create the S3 prefix `lake/gold/tickit/` in the Day 1 bucket.
2. THE Terraform_Module SHALL upload the Delta runtime jar from `instruction/day1/delta-spark_2.13-4.1.0.jar.txt` to `s3://<bucket>/library/delta-spark_2.13-4.1.0.jar`.
3. THE Terraform_Module SHALL expose the jar's S3 URI so the Delta_Load_Jobs can attach it via `--extra-jars`.
4. WHEN the jar source file changes, THE Terraform_Module SHALL detect the change (via `etag`/`filemd5`) and re-upload on the next `terraform apply`.

---

### Requirement 3: Delta Load Glue Jobs

**User Story:** As a data engineer, I want six Delta load Glue jobs whose names and arguments match exactly what `NT_Accelerate_LakeHouse_Master_Job` starts, so that the Delta branch of the master job runs end to end.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create six `aws_glue_job` resources named exactly `jb_DW_Delta_Load_DateDim`, `jb_DW_Delta_Load_VenueDim`, `jb_DW_Delta_Load_CategoryDim`, `jb_DW_Delta_Load_UserDim`, `jb_DW_Delta_Load_EventDim`, and `jb_DW_Delta_Load_SalesFact`.
2. THE Terraform_Module SHALL configure each Delta_Load_Job with default arguments covering the parameters the master job passes: `--p_batch_id`, `--p_job_name`, `--p_lakehouse_location`, `--p_region`, `--p_run_date`, `--p_src_databaseName`, `--p_src_tableName`, `--p_tar_databaseName`, `--p_tar_tablename`.
3. THE Terraform_Module SHALL attach the delta_jar to every Delta_Load_Job via `--extra-jars` and enable the Glue Data Catalog via `--enable-glue-datacatalog`.
4. WHEN a Delta_Load_Job runs, the job SHALL read the bronze Parquet for its source table and write/merge a Delta table at `<p_lakehouse_location>/<p_tar_tablename>`.
5. THE Terraform_Module SHALL set `glue_version`, `worker_type`, `number_of_workers`, `max_retries`, `timeout`, and `max_concurrent_runs` consistent with the Day 1 Glue job conventions.
6. WHEN a Delta_Load_Job completes, the job SHALL append a run record to `NT_Accelerate_JOB_LOG` and write its latest status to `NT_Accelarate_JOB_STATUS`, consistent with the Day 1 jobs.

---

### Requirement 4: Redshift Warehouse Provisioning

**User Story:** As a data platform engineer, I want an Amazon Redshift warehouse provisioned by Terraform, so that the Redshift_Load_Jobs have a target to load.

#### Acceptance Criteria

1. WHERE the input variable `enable_redshift` is `true`, THE Terraform_Module SHALL create an `aws_redshift_cluster` with database name `tickit`, a master username/password from input variables, `publicly_accessible` configurable, and `skip_final_snapshot = true`.
2. WHERE `enable_redshift` is `true`, THE Terraform_Module SHALL create an `aws_redshift_subnet_group` and a security group allowing ingress on port `5439` from the Glue connection security group.
3. THE Terraform_Module SHALL accept `redshift_node_type` (default `dc2.large`), `redshift_number_of_nodes` (default `1`), `redshift_database_name`, `redshift_master_username`, and `redshift_master_password` as input variables.
4. WHERE `enable_redshift` is `false`, THE Terraform_Module SHALL not create any Redshift cluster, subnet group, or Redshift security group.
5. THE Terraform_Module documentation SHALL state that the Redshift cluster bills hourly and must be destroyed (or `enable_redshift=false`) when the lab is idle.

---

### Requirement 5: Redshift Load Glue Jobs

**User Story:** As a data engineer, I want six Redshift load Glue jobs whose names and arguments match exactly what `NT_Accelerate_RedshiftDW_Master_Job` starts, so that the Redshift branch of the master job runs end to end.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create six `aws_glue_job` resources named exactly `jb_DW_Redshift_Load_DateDim`, `jb_DW_Redshift_Load_VenueDim`, `jb_DW_Redshift_Load_CategoryDim`, `jb_DW_Redshift_Load_UserDim`, `jb_DW_Redshift_Load_EventDim`, and `jb_DW_Redshift_Load_SalesFact`.
2. THE Terraform_Module SHALL configure each Redshift_Load_Job with default arguments covering the parameters the master job passes: `--p_batch_id`, `--p_job_name`, `--p_region`, `--p_run_date`, `--p_src_databaseName`, `--p_src_tableName`, `--p_tar_databaseName`, `--p_tar_tablename`, `--p_catalog_con`, `--p_postscript`, `--p_prescript`, `--p_redshift_temp`.
3. THE Terraform_Module SHALL attach every Redshift_Load_Job to the Redshift Glue connection and to the Day 1 `conRDS_tickit` connection as needed for VPC reachability.
4. WHEN a Redshift_Load_Job runs, the job SHALL read the bronze Parquet for its source table and load it into the Redshift target identified by `--p_tar_databaseName` / `--p_tar_tablename`, using `--p_prescript`, `--p_postscript`, and `--p_redshift_temp` for the staging / COPY / cleanup steps.
5. WHEN a Redshift_Load_Job completes, the job SHALL append a run record to `NT_Accelerate_JOB_LOG` and write its latest status to `NT_Accelarate_JOB_STATUS`, consistent with the Day 1 jobs.

---

### Requirement 6: Redshift Connection and Credentials

**User Story:** As a data platform engineer, I want the Redshift JDBC connection and its credentials stored in AWS, so that the Redshift_Load_Jobs can connect without hardcoded secrets.

#### Acceptance Criteria

1. WHERE `enable_redshift` is `true`, THE Terraform_Module SHALL create an `aws_glue_connection` of type `JDBC` named `conRedshift_tickit` pointing at `jdbc:redshift://<endpoint>:5439/tickit`.
2. THE Terraform_Module SHALL create an `aws_secretsmanager_secret` holding the Redshift connection info (`username`, `password`, `url`, `driver`) and SHALL grant the Glue role `secretsmanager:GetSecretValue` on it.
3. THE Terraform_Module SHALL set the `CATALOG_CON` value of every Redshift_Load_Job's JOB_CONFIG row to `conRedshift_tickit`, matching the connection name.
4. THE Terraform_Module SHALL NOT hardcode the Redshift password in any resource other than the Secrets Manager secret version and the cluster's own master password input.

---

### Requirement 7: JOB_CONFIG Rows for the Day 3 Jobs

**User Story:** As a data engineer, I want a `JOB_CONFIG` row for each of the twelve Day 3 Glue jobs that carries every column `NT_Accelerate_Is_Allow_Running` reads, so that the master jobs can resolve each job's parameters without a `KeyError`.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create twelve new `aws_dynamodb_table_item` resources in `NT_Accelerate_JOB_CONFIG`, one per Day 3 Glue job, keyed by `ID` values that do not collide with the Day 1 / Day 2 seed rows.
2. Each Day 3 row SHALL include the full superset of columns read by `NT_Accelerate_Is_Allow_Running`: `JOB_NAME`, `LAYER`, `MULTIPLE_RUN`, `REGION_NAME`, `SRC_DBNAME`, `SRC_TBLNAME`, `TRG_DBNAME`, `TRG_TBLNAME`, `INCREMENTAL_LOAD`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `PRESCRIPT`, `POSTSCRIPT`, `TEMP_FOLDER`.
3. WHEN the job is a Delta_Load_Job, THE Terraform_Module SHALL set `LAYER=LAKEHOUSE`, populate `LAKEHOUSE_LOCATION` with the gold location `s3://<bucket>/lake/gold/tickit/`, and set `CATALOG_CON`, `PRESCRIPT`, `POSTSCRIPT`, `TEMP_FOLDER` to empty strings.
4. WHEN the job is a Redshift_Load_Job, THE Terraform_Module SHALL set `LAYER=DW`, populate `CATALOG_CON=conRedshift_tickit`, `PRESCRIPT`, `POSTSCRIPT`, and `TEMP_FOLDER`, and set `LAKEHOUSE_LOCATION` to an empty string.
5. THE Terraform_Module SHALL set `SRC_DBNAME`/`SRC_TBLNAME` to the bronze source (e.g. `tickit` / `sales`) and `TRG_DBNAME`/`TRG_TBLNAME` to the Day 3 target for each job.
6. THE Terraform_Module SHALL set `MULTIPLE_RUN=FALSE` for the Day 3 rows.
7. THE Terraform_Module SHALL NOT modify or delete the seven Day 1 / Day 2 `JOB_CONFIG` seed rows.

---

### Requirement 8: MASTER_JOB_CONFIG Rows for Master Jobs 2 and 3

**User Story:** As a data engineer, I want `MASTER_JOB_CONFIG` rows for the LakeHouse and RedshiftDW master jobs, so that `NT_Accelerate_Read_Run_Type` returns `flag=true` when those state machines start.

#### Acceptance Criteria

1. THE Terraform_Module SHALL seed `NT_Accelerate_MASTER_JOB_CONFIG` with a row `ID=2` for the LakeHouse_Master_Job and a row `ID=3` for the RedshiftDW_Master_Job.
2. Each new row SHALL contain `RUN_TYPE=NEW`, `RERUN_DATE=2024-01-01`, `BATCH_ID=0`, `LAST_RUN_DATE=2024-01-01`, and `LAST_RUN_STATUS=NEW`, matching the Day 2 row `ID=1` shape.
3. THE Terraform_Module SHALL NOT modify the Day 2 `ID=1` row.

---

### Requirement 9: IAM Permissions for Delta and Redshift

**User Story:** As a data platform engineer, I want the Glue role extended with the Delta and Redshift permissions Day 3 needs, so that the transform jobs can read bronze, write gold, and load the warehouse.

#### Acceptance Criteria

1. THE Terraform_Module SHALL ensure the Glue role can read `s3://<bucket>/lake/bronze/*` and write `s3://<bucket>/lake/gold/*` and `s3://<bucket>/temporary/*`.
2. THE Terraform_Module SHALL grant the Glue role `secretsmanager:GetSecretValue` on the Redshift secret created in Requirement 6.
3. THE Terraform_Module SHALL grant the Glue role the permissions required to enumerate the Glue Data Catalog databases/tables it reads and writes.
4. THE Terraform_Module SHALL NOT attach `AdministratorAccess` or any AWS managed policy broader than the specific actions listed above.

---

### Requirement 10: Orchestration Run Order and Staging Gate

**User Story:** As a data engineer, I want the three master jobs to run in the order staging → Delta → Redshift with the staging gate enforced, so that the warehouse never loads from an incomplete bronze layer.

#### Acceptance Criteria

1. THE Day 3 run order SHALL be: Staging_Master_Job (Day 2) → LakeHouse_Master_Job → RedshiftDW_Master_Job.
2. WHEN the LakeHouse_Master_Job or RedshiftDW_Master_Job starts with `RUN_TYPE=NEW`, THE Step_Functions SHALL invoke `NT_Accelerate_Check_Staging_Master_Job_Status` and the LakeHouse/Redshift jobs SHALL run only when the Staging_Master_Job row (`ID=1`) has `LAST_RUN_DATE` equal to the run date and `LAST_RUN_STATUS=SUCCEEDED`; otherwise the execution SHALL fail at the `Staging master job not running yet` state.
3. THE Terraform_Module documentation SHALL describe how to start each master job (console or `aws stepfunctions start-execution`) in the required order.

---

### Requirement 11: Table Name Preservation (Intentional Typos)

**User Story:** As a data platform engineer, I want the DynamoDB table names with intentional misspellings preserved exactly, so that every Lambda and Glue job resolves the correct tables at runtime.

#### Acceptance Criteria

1. THE Terraform_Module SHALL reference `NT_Accelarate_JOB_STATUS` (missing `e` in "Accelerate") via a local and use it for every resource and policy that references that table.
2. THE Terraform_Module SHALL reference `NT_Acccelarate_WATERMARKTABLE` (triple `c`, missing `e`) via a local for every resource and policy that references that table.
3. THE Terraform_Module SHALL add a comment on each misspelled local value stating that the spelling is intentional and must not be corrected.

---

### Requirement 12: NEW vs RERUN for the Day 3 Layers

**User Story:** As a data engineer, I want the Delta and Redshift master jobs to support both NEW and RERUN execution modes, so that I can start a fresh daily transform or retry only the jobs that failed.

#### Acceptance Criteria

1. WHEN the LakeHouse_Master_Job or RedshiftDW_Master_Job starts with `RUN_TYPE=NEW`, THE Step_Functions SHALL delete all `NT_Accelarate_JOB_STATUS` rows before running the parallel branches.
2. WHEN the master job starts with `RUN_TYPE=RERUN`, THE Step_Functions SHALL skip the JOB_STATUS check and use the `RERUN_DATE` value as `run_date`.
3. WHEN `RUN_TYPE=RERUN` and a Day 3 job has a `FAILED` row in `NT_Accelarate_JOB_STATUS`, `NT_Accelerate_Is_Allow_Running` SHALL delete that row and return `is_ran=No` so the job reruns.
4. WHEN a Day 3 job has `MULTIPLE_RUN=FALSE` and a `NT_Accelerate_JOB_LOG` row already exists for the same `JOB_NAME` and `run_date`, `NT_Accelerate_Is_Allow_Running` SHALL return `is_ran=Yes` so the job is skipped.

---

### Requirement 13: Verification, Outputs, and Teardown

**User Story:** As a data platform engineer, I want module outputs and a teardown path, so that I can verify the Day 3 layer and tear it down cleanly.

#### Acceptance Criteria

1. THE Terraform_Module SHALL output the Day 3 Glue job names, the Delta gold location, the Redshift endpoint (when enabled), the Redshift connection name, and the Day 3 `JOB_CONFIG` row IDs.
2. THE Terraform_Module SHALL document the verification steps: bronze → gold Delta tables present under `lake/gold/tickit/`, Redshift tables populated, `JOB_LOG` / `JOB_STATUS` rows for all twelve Day 3 jobs.
3. WHEN `terraform destroy` is run, THE Terraform_Module SHALL delete the Day 3 Glue jobs, the Redshift cluster (with `skip_final_snapshot=true`), the Redshift connection, and the Day 3 seed rows, leaving Day 1 and Day 2 resources intact.
