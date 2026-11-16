# Day 1 — Data Ingestion: RDS SQL Server → S3 Bronze Layer

**Series:** NT Accelerate Lakehouse (AWS TechCamp 2022)  
**Day:** 1 of 3  
**Goal:** Extract all Tickit tables from a SQL Server Express RDS instance into an S3 data lake (bronze layer) as Snappy-compressed Parquet using AWS Glue, fully automated via Terraform.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Diagram](#architecture-diagram)
3. [Data Flow](#data-flow)
4. [AWS Resources](#aws-resources)
5. [Source Database — Tickit](#source-database--tickit)
6. [Extraction Jobs](#extraction-jobs)
7. [Control Plane — DynamoDB Tables](#control-plane--dynamodb-tables)
8. [Credentials — Secrets Manager](#credentials--secrets-manager)
9. [Networking](#networking)
10. [IAM](#iam)
11. [S3 Bucket Layout](#s3-bucket-layout)
12. [Known Gotchas](#known-gotchas)
13. [Cost Profile](#cost-profile)
14. [Deployment Quick-Start](#deployment-quick-start)

---

## Overview

Day 1 builds the **ingestion** (bronze) layer of the lakehouse. The source is a SQL Server Express database (Tickit) running on Amazon RDS. AWS Glue reads from it — either through the Glue Data Catalog (full-load jobs) or directly over JDBC with a watermark predicate (incremental Sales job) — and writes Snappy Parquet files to S3 partitioned by run date.

The entire stack is provisioned with `terraform apply` and torn down with `terraform destroy`. No resource is created by hand in the Console; the Console is used only to verify outputs.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│  us-east-1                                                               │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  S3: ntaccelerate-<suffix>                                        │   │
│  │   glue_script/   *.py scripts                                     │   │
│  │   library/       Genericlib.zip  openpyxl-3.0.10.tar.gz           │   │
│  │   raw/           csv / excel / json / xml sample files            │   │
│  │   lake/bronze/tickit/<table>/<run_date>/  ← Parquet output        │   │
│  │   sparkHistoryLogs/   temporary/                                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│            ↑ upload (terraform apply)        ↑ Parquet write             │
│                                              │                           │
│  ┌──────────────────────────────────────┐   │                           │
│  │  AWS Glue                            │───┘                           │
│  │                                      │                               │
│  │  Catalog DB: tickit                  │                               │
│  │  Connection: conRDS_tickit (JDBC)    │◄── sg_glue SG                │
│  │  Crawler: NT_Accelerate_cwl_RDSTickit│                               │
│  │                                      │                               │
│  │  Jobs (G.1X × 2, Glue 3.0):         │                               │
│  │   jb_Stg_Extract_Category  (full)    │                               │
│  │   jb_Stg_Extract_Date      (full)    │   reads Secrets Manager      │
│  │   jb_Stg_Extract_Event     (full)    │◄──────────────────────┐      │
│  │   jb_Stg_Extract_Listing   (full)    │   reads DynamoDB       │      │
│  │   jb_Stg_Extract_Users     (full)    │◄──────────┐           │      │
│  │   jb_Stg_Extract_Venue     (full)    │            │           │      │
│  │   jb_Stg_Extract_Sales     (incr.)   │            │           │      │
│  └────────────────────┬─────────────────┘            │           │      │
│           JDBC 1433   │                               │           │      │
│  ┌────────────────────▼──────┐  ┌────────────────────┴──┐  ┌─────┴──┐  │
│  │  RDS SQL Server Express   │  │  DynamoDB              │  │  SM    │  │
│  │  db.t3.micro, 20 GB gp2   │  │  JOB_CONFIG            │  │  SQL   │  │
│  │  database: tickit         │  │  JOB_LOG               │  │  creds │  │
│  │  sg_rds SG (port 1433)    │  │  JOB_STATUS            │  └────────┘  │
│  └───────────────────────────┘  │  WATERMARKTABLE        │             │
│                                  └────────────────────────┘             │
│  IAM: NT_Accelerate_GlueRole                                             │
│   (Glue trust, S3 bucket, DynamoDB tables, Secrets, CloudWatch Logs)    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

```
terraform apply
    │
    ├─► Create S3 bucket → upload scripts, library, raw samples, prefixes
    ├─► Create IAM role (NT_Accelerate_GlueRole)
    ├─► Create VPC networking (sg_rds, sg_glue, S3 endpoint)
    ├─► Create RDS SQL Server Express
    │       └─► Seed with tickit_script.sql (via sqlcmd local-exec)
    ├─► Create Secrets Manager secret (JDBC creds)
    ├─► Create DynamoDB tables + seed JOB_CONFIG + WATERMARKTABLE
    └─► Create Glue catalog DB, connection, crawler, 7 jobs

Operator:
    ├─► aws glue start-crawler  →  7 catalog tables tickit_dbo_*
    ├─► Trigger 6 full-load jobs
    │       └─► Reads catalog table → writes Parquet to lake/bronze/tickit/<table>/<date>/
    │           Logs SUCCEEDED to JOB_LOG + JOB_STATUS
    └─► Trigger jb_Stg_Extract_Sales (incremental)
            └─► Reads WATERMARKTABLE watermark (saletime)
                Queries RDS over JDBC: WHERE saletime > <last_value>
                Writes new rows as Parquet
                Advances WATERMARKTABLE.DATA_VALUES to max(saletime)
```

---

## AWS Resources

| Resource | Name / ID | Purpose |
|----------|-----------|---------|
| S3 Bucket | `ntaccelerate-<suffix>` | Scripts, library, raw landing, bronze Parquet |
| IAM Role | `NT_Accelerate_GlueRole` | Glue service role |
| Security Group | `NT_Accelerate-sg-rds` | Protects RDS port 1433 |
| Security Group | `NT_Accelerate-sg-glue` | Attached to Glue connection ENIs |
| VPC Endpoint | S3 Gateway | Allows Glue to reach S3 without NAT |
| RDS Instance | `nt-accelerate-sqlserver` | SQL Server Express source DB |
| Secrets Manager | `SQLSource_Database_Connection_Info` | JDBC credentials |
| DynamoDB | `NT_Accelerate_JOB_CONFIG` | Per-job config parameters |
| DynamoDB | `NT_Accelerate_JOB_LOG` | Run history (one row per run) |
| DynamoDB | `NT_Accelarate_JOB_STATUS` | Latest status per job |
| DynamoDB | `NT_Acccelarate_WATERMARKTABLE` | Incremental load watermarks |
| Glue DB | `tickit` | Data Catalog database |
| Glue Connection | `conRDS_tickit` | JDBC connection to RDS |
| Glue Crawler | `NT_Accelerate_cwl_RDSTickit` | Crawls RDS → catalog tables |
| Glue Jobs | 7 jobs (6 full + 1 incremental) | ETL extraction |

---

## Source Database — Tickit

The Tickit database is a sample event ticketing schema provided by AWS. It runs on SQL Server Express in RDS and is seeded from `tickit_script.sql`.

| Table | Rows | Extract type |
|-------|------|-------------|
| `dbo.category` | 11 | Full load |
| `dbo.date` | 365 | Full load |
| `dbo.event` | 8,659 | Full load |
| `dbo.listing` | 192,497 | Full load |
| `dbo.users` | 49,990 | Full load |
| `dbo.venue` | 202 | Full load |
| `dbo.sales` | 172,448 | **Incremental** (watermark: `saletime`) |

After the Glue crawler runs, each table appears in the Glue Data Catalog as `tickit_dbo_<table>`.

---

## Extraction Jobs

All jobs share the same runtime configuration:

| Setting | Value |
|---------|-------|
| Glue version | 3.0 |
| Worker type | G.1X |
| Workers | 2 |
| Max retries | 0 |
| Timeout | 15 min |
| Bookmark | Enabled |
| Library | `s3://<bucket>/library/Genericlib.zip` |
| Extra modules | `openpyxl-3.0.10.tar.gz` |

### Full-load jobs (6)

Each full-load job reads from the Glue Data Catalog (`from_catalog`) and writes Parquet:

```
s3://<bucket>/lake/bronze/tickit/<table>/<run_date>/
```

Parameters passed to each job:

| Parameter | Value |
|-----------|-------|
| `--p_job_name` | job name |
| `--p_run_date` | `var.run_date` |
| `--p_batch_id` | `var.batch_id` |
| `--p_region` | `us-east-1` |
| `--p_is_incremental_load` | `False` |
| `--p_catalog_conn` | `conRDS_tickit` |
| `--p_src_databaseName` | `tickit` |
| `--p_src_tableName` | `tickit_dbo_<table>` |
| `--p_tar_databaseName` | `s3://<bucket>/lake/bronze/tickit/` |
| `--p_tar_tablename` | `<table>` |

### Incremental Sales job

`jb_Stg_Extract_Sales` reads the watermark from `WATERMARKTABLE`, queries RDS over JDBC with `WHERE saletime > <last_value>`, appends only new rows to Parquet, then updates `WATERMARKTABLE.DATA_VALUES` to `max(saletime)`. Initial watermark: `2008-12-31 12:58:19`.

---

## Control Plane — DynamoDB Tables

> **Note:** The table names below include intentional misspellings that match `Genericlib.py` exactly. Do **not** correct them.

### NT_Accelerate_JOB_CONFIG
- PK: `ID` (Number)
- Seeded with one row per job containing all `--p_*` parameters
- Serves as the config source of truth

### NT_Accelerate_JOB_LOG
- PK: `ID` (String)
- Written by each job run: `batch_id`, `job_name`, `run_date`, `status`, `error_msg`, `start_time`, `end_time`, row counts

### NT_Accelarate_JOB_STATUS ← note spelling
- PK: `JOB_NAME` (String)
- Updated by each run to reflect the latest status (SUCCEEDED / FAILED)

### NT_Acccelarate_WATERMARKTABLE ← note spelling
- PK: `ID` (Number), SK: `JOB_NAME` (String)
- Stores `COLUMN_NAMES`, `DATA_TYPES`, `DATA_VALUES`, `QUERY_STRING`
- Sales row seeded with:
  - `COLUMN_NAMES: ["saletime"]`
  - `DATA_VALUES: ["2008-12-31 12:58:19"]`
  - `QUERY_STRING: "select ... from dbo.sales where "`

---

## Credentials — Secrets Manager

Secret name: `SQLSource_Database_Connection_Info`

```json
{
  "db_username": "<rds_username>",
  "db_password": "<rds_password>",
  "db_url": "jdbc:sqlserver://<endpoint>:1433;databaseName=tickit",
  "driver_name": "com.microsoft.sqlserver.jdbc.SQLServerDriver"
}
```

> **Important:** The URL must use `databaseName=` (not `database=`). The Glue scripts pass this value directly to Spark JDBC.

---

## Networking

```
Default VPC (vpc-xxxxxxxx)
│
├── sg_rds (NT_Accelerate-sg-rds)
│    Inbound:  TCP 1433 from sg_glue  ← Glue workers reach RDS
│              TCP 1433 from <local IP>  ← sqlcmd seed during apply
│    Outbound: all
│
├── sg_glue (NT_Accelerate-sg-glue)
│    Inbound:  all from sg_glue (self-ref)  ← required by Glue ENI
│    Outbound: all
│
└── VPC S3 Gateway Endpoint
     Service: com.amazonaws.<region>.s3
     Required by Glue to reach S3 (scripts, logs, temp) without NAT
```

The local IP rule (`rds_ingress_local`) is detected dynamically via `checkip.amazonaws.com` on each `terraform apply` — no manual SG edits needed.

---

## IAM

**Role:** `NT_Accelerate_GlueRole`  
**Trust:** `glue.amazonaws.com`  
**Managed policy:** `AWSGlueServiceRole`

**Inline scoped policy:**

| Statement | Actions | Resource |
|-----------|---------|----------|
| `S3BucketAccess` | `s3:ListBucket` | The provisioned bucket only |
| `S3ObjectAccess` | `s3:GetObject`, `PutObject`, `DeleteObject` | Bucket objects only |
| `DynamoDBControlTables` | CRUD + Query + Scan | The 4 DynamoDB tables only |
| `SecretsManagerGetSecret` | `secretsmanager:GetSecretValue` | The credentials secret only |
| `CloudWatchLogs` | CreateLogGroup, CreateLogStream, PutLogEvents | `arn:aws:logs:*:*:*` |

---

## S3 Bucket Layout

```
s3://ntaccelerate-<suffix>/
├── glue_script/
│   ├── jb_Stg_Extract_Category.py
│   ├── jb_Stg_Extract_Date.py
│   ├── jb_Stg_Extract_Event.py
│   ├── jb_Stg_Extract_Listing.py
│   ├── jb_Stg_Extract_Sales.py
│   ├── jb_Stg_Extract_Users.py
│   ├── jb_Stg_Extract_Venue.py
│   └── jb_Stg_Extract_ExcelFile.py
├── library/
│   ├── Genericlib.zip
│   └── openpyxl-3.0.10.tar.gz
├── raw/
│   ├── csv/SalesEvent.csv
│   ├── excel/SalesEvent.xlsx
│   ├── json/user.json
│   └── xml/customer.xml
├── lake/
│   └── bronze/
│       └── tickit/
│           ├── category/<run_date>/*.parquet
│           ├── date/<run_date>/*.parquet
│           ├── event/<run_date>/*.parquet
│           ├── listing/<run_date>/*.parquet
│           ├── sales/<run_date>/*.parquet
│           ├── users/<run_date>/*.parquet
│           └── venue/<run_date>/*.parquet
├── sparkHistoryLogs/
└── temporary/
```

---

## Known Gotchas

1. **DynamoDB table name typos are intentional.** `Genericlib.py` contains `NT_Accelarate_JOB_STATUS` (missing `e`) and `NT_Acccelarate_WATERMARKTABLE` (triple `c`, missing `e`). Fixing the spelling breaks the jobs at runtime with `ResourceNotFoundException`.

2. **JDBC URL form.** Must use `databaseName=tickit`, not `database=tickit`. The scripts pass the URL directly to Spark JDBC which requires the `databaseName=` form.

3. **`p_catalog_conn` is required even for full-load jobs.** The scripts call `getResolvedOptions` for all 10 parameters including `p_catalog_conn`. Omitting it causes a job argument resolution error at startup.

4. **sg_glue requires a self-referencing inbound rule.** Glue places ENIs in the connection's subnet; without an all-traffic self-referencing rule on `sg_glue`, crawlers fail with `At least one security group must open all ingress ports`.

5. **S3 Gateway endpoint is required.** Glue cannot reach S3 from within the VPC without either an S3 Gateway endpoint or a NAT gateway. The endpoint is free; a NAT gateway costs ~$32/month.

6. **RDS seeding is slow on db.t3.micro.** The `tickit_script.sql` contains 424k single-row INSERTs. The `batch_seed.py` script rewrites them into multi-row batches to reduce round trips; even so, the large tables (`listing`, `sales`) are constrained by the 1 GB RAM limit of `db.t3.micro`.

7. **SQL Server Express requires `license_model = "license-included"`.** AWS manages the license and only supports `db.t3.micro` and `db.t3.small` for Express edition.

---

## Cost Profile

> Region: `us-east-1`

| Resource | Idle cost | Active cost |
|----------|-----------|-------------|
| RDS db.t3.micro (running) | $0.017/hr (~$12/mo) | same |
| RDS db.t3.micro (stopped) | Storage only: ~$0.10/mo | — |
| Secrets Manager | $0.40/mo | same |
| S3 (scripts + Parquet) | < $0.01/mo | same |
| DynamoDB (PAY_PER_REQUEST, tiny) | < $0.01/mo | same |
| Glue Crawler (once, ~5 min) | — | ~$0.17 |
| Glue Jobs (7 jobs × ~5 min × G.1X × 2) | — | ~$0.50 |

**Stop RDS when not in use:**
```bash
aws rds stop-db-instance --db-instance-identifier nt-accelerate-sqlserver
```

**Full teardown:**
```bash
aws s3 rm s3://<bucket> --recursive   # empty bucket first (versioned)
cd infra && terraform destroy -auto-approve
```

---

## Deployment Quick-Start

```bash
# 1. Prerequisites
brew install sqlcmd terraform awscli git-lfs

# 2. Pull the LFS-tracked SQL seed file
git lfs pull --include="instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"

# 3. Configure AWS credentials
aws configure   # or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

# 4. Create terraform.tfvars (never commit this file)
cat > infra/terraform.tfvars <<EOF
bucket_name          = "ntaccelerate-<your-unique-suffix>"
db_username          = "admin"
db_password          = "YourPass123!"
source_artifacts_dir = "../instruction/day1"
EOF

# 5. Apply
cd infra
terraform init
terraform apply -auto-approve

# 6. Seed RDS (if null_resource.db_seed skipped due to LFS pointer)
python3 scripts/batch_seed.py \
  --server "$(terraform output -raw rds_endpoint | sed 's|jdbc:sqlserver://||;s|:1433.*||'),1433" \
  --user admin --password "YourPass123!" \
  --script "../instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"

# 7. Run the crawler
aws glue start-crawler --name NT_Accelerate_cwl_RDSTickit

# 8. Trigger full-load jobs
for job in jb_Stg_Extract_Category jb_Stg_Extract_Date jb_Stg_Extract_Event \
           jb_Stg_Extract_Listing jb_Stg_Extract_Users jb_Stg_Extract_Venue; do
  aws glue start-job-run --job-name $job
done

# 9. Trigger incremental Sales job
aws glue start-job-run --job-name jb_Stg_Extract_Sales
```

---

*Next: [Day 2 — Orchestration](./day2-orchestration.md) (planned)*
