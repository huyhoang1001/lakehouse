# NT Accelerate Day 1 Ingestion — Requirements

## Introduction

This spec rebuilds the AWS TechCamp Day 1 lab ("NT_Accelerate") with Terraform instead of the AWS Console. The lab extracts the Tickit SQL Server database (plus flat files) into an S3 data lake (bronze layer) as Snappy-compressed Parquet using AWS Glue, driven by DynamoDB configuration, Secrets Manager credentials, and watermark-based incremental loads, with per-run logging.

**Constraint:** AWS Console is used **only to verify**. Every resource is provisioned through Terraform (`apply`/`destroy`).

**Source artifacts to reuse verbatim** (under `instruction/day1/Day 1 source 3/Day 1 source/` and `instruction/day1/tickit_db 2/tickit_db/`):
- Glue scripts: `jb_Stg_Extract_Category.py`, `jb_Stg_Extract_Date.py`, `jb_Stg_Extract_Event.py`, `jb_Stg_Extract_Listing.py`, `jb_Stg_Extract_Sales.py`, `jb_Stg_Extract_Users.py`, `jb_Stg_Extract_Venue.py`, `jb_Stg_Extract_ExcelFile.py`
- Shared library: `S3/library/Genericlib/Genericlib.py` (zip into `Genericlib.zip`), plus `S3/library/openpyxl-3.0.10.tar.gz`
- Raw samples: `S3/raw/{csv/SalesEvent.csv, excel/SalesEvent.xlsx, json/user.json, xml/customer.xml}`
- Seed data: `tickit_script.sql` (7 tables: category, date, event, listing, sales, users, venue)

---

## 1. S3 foundation and artifact storage

### Requirement 1
The stack SHALL provision a single S3 bucket to hold Glue scripts, shared libraries, raw landing files, data-lake output, Spark logs, and temp space.

WHEN the stack is applied to a target AWS account
THE SYSTEM SHALL create one S3 bucket whose name is configurable via a Terraform variable

WHEN the bucket is created
THE SYSTEM SHALL enable default SSE-S3 encryption, block all public access, and enable versioning

WHEN artifacts are deployed
THE SYSTEM SHALL upload the Glue `.py` scripts to `glue_script/`, `Genericlib.zip` and `openpyxl-3.0.10.tar.gz` to `library/`, raw samples to `raw/<type>/`, and create the prefixes `lake/bronze/tickit/`, `sparkHistoryLogs/`, and `temporary/`

WHEN the bucket name is already taken in the target region
THE SYSTEM SHALL fail at apply with a clear error so the operator changes the variable

## 2. IAM execution role (least privilege)

### Requirement 2
Glue SHALL run all jobs and the crawler under a single service role with the minimum permissions needed.

WHEN the role is created
THE SYSTEM SHALL create `NT_Accelerate_GlueRole` with a `glue.amazonaws.com` trust policy

WHEN policies are attached
THE SYSTEM SHALL grant Glue service permissions, read/write to the provisioned S3 bucket only, read/write to the four DynamoDB control tables only, read access to the DB credentials secret only, and CloudWatch Logs writes

WHEN a job attempts an action outside these grants
THE SYSTEM SHALL deny it (no account-wide wildcard S3/DynamoDB)

## 3. Network and RDS source database

### Requirement 3
The stack SHALL provision a SQL Server Express instance hosting the Tickit schema as the extraction source, reachable from AWS Glue.

WHEN the stack is applied
THE SYSTEM SHALL provision a `db.t3.micro` SQL Server Express RDS instance in `us-east-1` with a 20 GB gp2 volume and credentials from Terraform variables

WHEN the instance is available
THE SYSTEM SHALL make it reachable from the Glue connection by placing the RDS security group and the Glue connection in the same VPC, with the RDS security group allowing inbound TCP 1433 from the Glue security group

WHEN the RDS instance is not needed
THE SYSTEM SHALL support stopping the instance so only storage is billed

### Requirement 4
The stack SHALL seed the Tickit database with the provided SQL script.

WHEN the RDS instance is reachable and empty
THE SYSTEM SHALL execute `tickit_script.sql` to create and populate all seven tables (category, date, event, listing, sales, users, venue)

WHEN seeding is re-run against a populated database
THE SYSTEM SHALL remain idempotent by guarding with object-existence checks or by only seeding once (a `null_resource` triggered by a content hash)

## 4. Secrets Manager for database credentials

### Requirement 5
The stack SHALL store RDS connection details in Secrets Manager so Glue jobs never hold credentials in code.

WHEN the secret is created
THE SYSTEM SHALL create a secret named `SQLSource_Database_Connection_Info` containing JSON keys `db_username`, `db_password`, `db_url` (JDBC URL using `databaseName=tickit`), and `driver_name` (`com.microsoft.sqlserver.jdbc.SQLServerDriver`)

WHEN a Glue job reads the secret
THE SYSTEM SHALL grant the Glue role `secretsmanager:GetSecretValue` limited to this secret only

## 5. DynamoDB configuration and control tables

### Requirement 6
The stack SHALL create four DynamoDB tables that drive job configuration and record job state.

WHEN the stack is applied
THE SYSTEM SHALL create `NT_Accelerate_JOB_CONFIG`, `NT_Accelerate_JOB_LOG`, `NT_Accelarate_JOB_STATUS`, and `NT_Acccelarate_WATERMARKTABLE`

WHEN the shared library `Genericlib.py` references a table
THE SYSTEM SHALL name each table exactly as the library spells it (including the misspellings `NT_Accelarate_JOB_STATUS` and `NT_Acccelarate_WATERMARKTABLE`), so jobs do not fail at runtime on missing tables

WHEN the tables are created
THE SYSTEM SHALL seed `JOB_CONFIG` with one row per extraction job and `WATERMARKTABLE` with a Sales watermark row (column `saletime`, initial value `2008-12-31 12:58:19`)

## 6. Glue data catalog, connection, and crawler

### Requirement 7
The stack SHALL populate the Glue Data Catalog by crawling the RDS Tickit database.

WHEN the stack is applied
THE SYSTEM SHALL create a Glue catalog database named `tickit`, a JDBC connection `conRDS_tickit`, and a crawler `NT_Accelerate_cwl_RDSTickit` targeting the Tickit JDBC source with output to the `tickit` database

WHEN the crawler runs
THE SYSTEM SHALL produce one catalog table per Tickit table (prefixed `tickit_dbo_`) so jobs can read them via `from_catalog`

## 7. Glue extraction jobs — full load

### Requirement 8
The stack SHALL create a Glue job for each full-load Tickit table using the provided scripts.

WHEN the stack is applied
THE SYSTEM SHALL create Glue jobs `jb_Stg_Extract_Category`, `jb_Stg_Extract_Date`, `jb_Stg_Extract_Event`, `jb_Stg_Extract_Listing`, `jb_Stg_Extract_Users`, and `jb_Stg_Extract_Venue`, each using its provided `.py` script from `s3://<bucket>/glue_script/`

WHEN each job is configured
THE SYSTEM SHALL set Spark, Glue 3.0, Python 3, G.1X workers (2), bookmark enabled, 15-minute timeout, the `Genericlib.zip` library, temp dir, Spark UI log path, and all required `--p_*` parameters with `p_is_incremental_load=False`

WHEN a full-load job succeeds
THE SYSTEM SHALL write Snappy-compressed Parquet to `s3://<bucket>/lake/bronze/tickit/<table>/<run_date>/` and write a SUCCEEDED row to `JOB_LOG` and `JOB_STATUS`

WHEN a full-load job fails
THE SYSTEM SHALL write a FAILED row to `JOB_LOG` and `JOB_STATUS` with the error message and exit without crashing the run

## 8. Glue extraction job — incremental load (Sales)

### Requirement 9
The stack SHALL create an incremental Glue job for the Sales table using a watermark.

WHEN the stack is applied
THE SYSTEM SHALL create `jb_Stg_Extract_Sales` with `p_is_incremental_load=True`

WHEN the Sales job runs
THE SYSTEM SHALL read the watermark from `WATERMARKTABLE`, build a `saletime > <last_value> AND 1=1` predicate, query RDS over JDBC using Secrets Manager credentials, and write only new rows as Parquet

WHEN the Sales job completes with new rows
THE SYSTEM SHALL update `WATERMARKTABLE.DATA_VALUES` to the max `saletime` so the next run continues from there

## 9. Flat-file ingestion (optional)

### Requirement 10
The stack MAY create a flat-file extraction job for the provided CSV/Excel/JSON/XML samples.

WHEN this optional job is enabled via a Terraform variable
THE SYSTEM SHALL create `jb_Stg_Extract_ExcelFile` using the provided script and the `openpyxl` library, reading from `s3://<bucket>/raw/...` and writing Parquet to the bronze layer

WHEN this optional job is disabled (default)
THE SYSTEM SHALL skip its creation without affecting the RDS extraction jobs

## 10. Verification via AWS Console

### Requirement 11
All resources SHALL be verifiable from the AWS Console without creating anything there.

WHEN provisioning is complete
THE SYSTEM SHALL expose Terraform outputs for the bucket name, Glue job names, RDS endpoint, secret ARN, and DynamoDB table names so the operator can verify in the Console

WHEN the operator opens the Console
THE SYSTEM SHALL let the operator confirm catalog tables exist, Parquet files exist under `lake/bronze/tickit/`, `JOB_LOG` shows SUCCEEDED rows, `JOB_STATUS` reflects the latest state, and the secret is present — without using the Console to create resources

## 11. Teardown and cost control

### Requirement 12
The stack SHALL be cheap to idle and fully destroyable.

WHEN the exercise is finished
THE SYSTEM SHALL be removable with `terraform destroy`, deleting the bucket (after emptying), RDS instance, Glue resources, DynamoDB tables, secret, and IAM role

WHEN cost must be minimized between sessions
THE SYSTEM SHALL support stopping the RDS instance and deleting the Secrets Manager secret while keeping the S3 data
