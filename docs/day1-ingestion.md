# Building a Data Lakehouse on AWS — Day 1: Ingestion Layer

*Part 1 of a 3-part series on building a production-grade data lakehouse on AWS using Terraform.*

---

If you have ever been asked to migrate an operational SQL Server database into a cloud data platform, you have faced the same question every data engineer faces eventually: how do you get data out of a relational system and into a format your analytics stack can actually use — reliably, cheaply, and without babysitting it?

This post walks through how we built the ingestion (bronze) layer of a lakehouse on AWS. We extract seven tables from a SQL Server RDS database into S3 as Parquet using AWS Glue, with a proper control plane built on DynamoDB and credentials managed in Secrets Manager. Everything is provisioned with Terraform so the whole stack can be stood up or torn down in minutes.

Before getting into the implementation, it helps to understand why we made the architectural choices we did — because those choices are the same ones you would face in a real production system.

---

## Why a lakehouse, and why this architecture?

A data warehouse gives you fast structured queries but forces you to define schemas upfront and pays for compute even when idle. A data lake gives you cheap, flexible storage but no query governance. A **lakehouse** tries to get both: raw data lands in object storage (S3) in an open columnar format (Parquet), and a catalog layer (Glue Data Catalog) makes it queryable by Athena, Redshift Spectrum, or EMR without duplicating the data.

The ingestion pattern we use here — often called **ELT** (Extract, Load, Transform) — deliberately keeps the extraction stage dumb. We pull data as-is into the bronze (raw) layer and let downstream transformations handle cleaning and enrichment. This matters for three reasons:

1. **Replayability.** If your transformation logic has a bug, you can re-run it against the original bronze data without going back to the source system.
2. **Auditability.** The bronze layer is an immutable record of what the source system contained at the time of extraction.
3. **Decoupling.** Your source system (SQL Server on RDS here) doesn't need to know anything about your analytics stack. You're pulling from it, not pushing to it.

---

## The medallion architecture

The pattern underlying this series is the **medallion architecture**, a layered approach to organizing data in a lakehouse:

```
Source Systems
     │
     ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Bronze    │───►│   Silver    │───►│    Gold     │
│  Raw copy   │    │  Cleaned,   │    │  Aggregated,│
│  of source  │    │  conformed  │    │  business-  │
│  (Parquet)  │    │  (Delta/    │    │  ready      │
│             │    │  Iceberg)   │    │  (Redshift) │
└─────────────┘    └─────────────┘    └─────────────┘
    Day 1              Day 2              Day 3
```

Day 1 (this post) covers the bronze layer — getting raw data from the source into S3. Day 2 adds orchestration and the silver layer. Day 3 covers the gold layer and Redshift.

In production, teams typically add a fourth consideration: **governance** — table ACLs via AWS Lake Formation, column-level masking for PII, and cross-account access. We keep that out of scope for this series but flag where you would plug it in.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AWS us-east-1                                                           │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  S3: ntaccelerate-<suffix>                                        │   │
│  │   glue_script/   *.py scripts                                     │   │
│  │   library/       Genericlib.zip  openpyxl-3.0.10.tar.gz           │   │
│  │   raw/           csv / excel / json / xml sample files            │   │
│  │   lake/bronze/tickit/<table>/<run_date>/  ← Parquet output        │   │
│  │   sparkHistoryLogs/   temporary/                                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│            ↑ upload (Terraform)              ↑ Parquet write             │
│                                              │                           │
│  ┌──────────────────────────────────────┐   │                           │
│  │  AWS Glue (Spark, G.1X × 2)          │───┘                           │
│  │  Catalog DB: tickit                  │                               │
│  │  Connection: conRDS_tickit (JDBC)    │◄── sg_glue SG                │
│  │  Crawler: NT_Accelerate_cwl_RDSTickit│                               │
│  │  Jobs: 6 full-load + 1 incremental   │◄── DynamoDB (config/state)   │
│  └────────────────────┬─────────────────┘◄── Secrets Manager (creds)   │
│           JDBC 1433   │                                                  │
│  ┌────────────────────▼──────┐  ┌───────────────────────┐              │
│  │  RDS SQL Server Express   │  │  DynamoDB (4 tables)   │              │
│  │  db.t3.micro, 20 GB gp2   │  │  JOB_CONFIG            │              │
│  │  database: tickit (7 tbl) │  │  JOB_LOG               │              │
│  │  sg_rds SG (port 1433)    │  │  JOB_STATUS            │              │
│  └───────────────────────────┘  │  WATERMARKTABLE        │              │
│                                  └───────────────────────┘              │
│  IAM: NT_Accelerate_GlueRole  |  VPC S3 Gateway Endpoint                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Design decisions worth explaining

### Why Parquet?

Parquet is column-oriented. For analytical workloads — aggregations, filtered scans, group-bys — it reads only the columns it needs and skips row groups that don't match filter predicates. In practice this means 10–100× less I/O than row-based formats like CSV. Snappy compression adds another 3–5× reduction in storage with negligible CPU overhead.

In production you would also consider **Delta Lake** or **Apache Iceberg** on top of Parquet to get ACID transactions, schema evolution, and time-travel on the bronze layer. For Day 1 raw extraction, plain Parquet is sufficient — we layer Delta/Iceberg into the silver layer in Day 2.

### Why partition by run date, not by a business date?

We partition the output path as `lake/bronze/tickit/<table>/<run_date>/`. This means each job run produces a new S3 prefix. A business-date partition (e.g. by `saletime` for the Sales table) would produce smaller files and better Athena query pruning, but it complicates re-runs: if you re-extract today's data, you need to either overwrite or deduplicate. Using run date keeps the bronze layer append-only and idempotent — you can always trace which physical files came from which pipeline run.

Silver layer transformations can repartition by business date after deduplication.

### Why S3 over a data warehouse directly?

The common alternative is to load from RDS into Redshift directly using the Redshift COPY command or AWS DMS. The problem is cost and flexibility. Redshift charges for storage and compute even at rest. S3 costs ~$0.023/GB/month with no compute charge when idle. By landing in S3 first, you can query the same data with Athena (pay-per-query), Redshift Spectrum (pay-per-query), or EMR (pay-per-job) depending on the workload without moving it again.

### Why AWS Glue over custom ETL?

Three reasons: managed Spark without cluster administration, native integration with the Glue Data Catalog (which Athena and Redshift Spectrum also read), and job bookmarking built in. Bookmarking lets Glue track how far it has read from a source so you don't re-process records on retry without writing custom state management.

The tradeoff is cold start time — a Glue job spins up a Spark cluster, which takes 1–3 minutes before any data moves. For latency-sensitive pipelines you would use AWS Lambda or Kinesis Firehose instead. For daily/hourly batch extraction, Glue's cold start is acceptable.

### Why DynamoDB for the control plane?

A common pattern in Glue-based pipelines is to externalize job configuration and state into a NoSQL table. DynamoDB works well here because:

- **Schema flexibility.** Each job can have different parameters without an ALTER TABLE.
- **No idle cost.** PAY_PER_REQUEST billing means you pay nothing when jobs aren't running.
- **Atomic updates.** A single `UpdateItem` call advances the watermark and updates the job status atomically, with no risk of a partial write that corrupts the state.

In a larger production system you might replace `JOB_CONFIG` with AWS Systems Manager Parameter Store or a dedicated orchestration service (Step Functions, Airflow). The key principle — separating job configuration from job code — stays the same.

### Why watermarks instead of full loads for Sales?

The Sales table (172k rows) grows continuously. Re-extracting all 172k rows every day to find the new ones is wasteful and doesn't scale as the table grows to millions of rows. A **high-watermark** approach stores the maximum value of an ordered column (`saletime`) from the last successful run and only extracts rows where `saletime > last_value`.

This works reliably when:
- The watermark column is indexed in the source
- Rows are never updated after insertion (or updates don't matter)
- The column is monotonically increasing

`saletime` satisfies all three. For tables with updates (slowly changing dimensions), you would use a `UPDATED_AT` timestamp column instead, or switch to Change Data Capture (CDC) using AWS DMS.

### Why Secrets Manager instead of environment variables?

Credentials passed as Glue job parameters appear in the job run history in the Console and in CloudTrail logs. Secrets Manager keeps the actual values encrypted at rest (KMS) and only the secret ARN appears in job configuration. The Glue role is granted `GetSecretValue` on that specific ARN only — not all secrets in the account.

In production, you would also enable automatic rotation on the Secrets Manager secret so the RDS password rotates without any code changes.

---

## The source: Tickit database

Tickit is a sample event ticketing schema modelling a marketplace where sellers list tickets and buyers purchase them. It has 7 tables across two extraction patterns:

| Table | Rows | Extract | Key columns |
|-------|------|---------|-------------|
| `dbo.category` | 11 | Full load | catid, catgroup, catname |
| `dbo.date` | 365 | Full load | dateid, caldate, day, week, month |
| `dbo.venue` | 202 | Full load | venueid, venuename, venuecity, venuestate |
| `dbo.event` | 8,659 | Full load | eventid, venueid, catid, dateid, eventname |
| `dbo.users` | 49,990 | Full load | userid, username, firstname, lastname, email |
| `dbo.listing` | 192,497 | Full load | listid, sellerid, eventid, numtickets, priceperticket |
| `dbo.sales` | 172,448 | **Incremental** | saleid, listid, sellerid, buyerid, **saletime** |

The six dimension/fact tables that don't change are extracted with full loads. Sales, the transaction table, uses a watermark on `saletime`.

---

## How the extraction works

### Full-load jobs

The six full-load jobs all follow the same pattern implemented in `Genericlib.py`:

1. Read job parameters from Glue's `getResolvedOptions` (10 `--p_*` arguments)
2. Create a Glue DynamicFrame from the Data Catalog table (`from_catalog`)
3. Write as Snappy Parquet to `s3://<bucket>/lake/bronze/tickit/<table>/<run_date>/`
4. Write a SUCCEEDED (or FAILED) row to `JOB_LOG` with row counts, start/end time
5. Update `JOB_STATUS` with the latest status for this job name

The Glue Data Catalog acts as the schema registry here. The crawler discovers column names and types from the SQL Server schema and stores them in the catalog; the extraction job reads from the catalog rather than querying SQL Server's information schema directly. This means the job doesn't need a live JDBC connection — it reads the catalogued schema and pulls data through the connection.

### Incremental Sales job

The Sales job uses a different path:

1. Read the watermark from `WATERMARKTABLE`: `DATA_VALUES = ["2008-12-31 12:58:19"]`
2. Fetch JDBC credentials from Secrets Manager
3. Build a predicate: `saletime > '2008-12-31 12:58:19'`
4. Query RDS directly over JDBC (not via catalog) with that predicate
5. Write new rows as Parquet, partitioned by run date
6. Update `WATERMARKTABLE.DATA_VALUES` to `max(saletime)` from the result set

The `QUERY_STRING` column in `WATERMARKTABLE` stores the base SQL query prefix so the script can construct the full query without hardcoding table structure. This makes the same library code reusable for any table with a watermark column.

---

## Infrastructure as Code — why every resource is in Terraform

The original lab was done by hand in the AWS Console. That approach works for a one-time exercise, but it has three problems in a real team:

1. **Reproducibility.** Another team member can't recreate the environment from the Console screenshots.
2. **Drift.** Someone adjusts a security group rule manually and the next deployment doesn't include it.
3. **Cost.** Resources that were created manually are easy to forget and leave running.

With Terraform, the entire stack is defined as code, reviewed in pull requests, and torn down cleanly when not needed. The `terraform.tfstate` file tracks what was created, so `terraform destroy` removes everything — including resources like security group rules that were added after initial creation.

One real-world lesson from this build: manual fixes made during debugging (adding a security group rule, creating a VPC endpoint) need to be codified back into Terraform immediately. We learned this the hard way — the second `terraform apply` overwrote manual SG rules, breaking the crawler. The rule is: if you touch it in the Console, you add it to the `.tf` file before the next apply.

---

## Networking: the two things Glue needs that most tutorials skip

Two networking requirements are almost never mentioned in Glue tutorials but will block you in a fresh AWS account:

**1. The sg_glue security group needs a self-referencing inbound rule.**

Glue places Elastic Network Interfaces (ENIs) in the subnet you specify on the connection. The driver and executor processes communicate over those ENIs. AWS requires that the security group attached to the connection allows all inbound traffic from itself — otherwise Glue refuses to start the job with the error:

> At least one security group must open all ingress ports.

This has nothing to do with your source database. It's about inter-process communication within the Glue job itself.

```hcl
resource "aws_security_group_rule" "sg_glue_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.sg_glue.id
  security_group_id        = aws_security_group.sg_glue.id
}
```

**2. Glue needs an S3 Gateway endpoint or a NAT gateway.**

Glue workers need to reach S3 to download scripts, write output, and push Spark logs. If the subnet has no route to S3, the job fails immediately with:

> Could not find S3 endpoint or NAT gateway for subnetId

A NAT gateway costs ~$32/month plus data transfer. An S3 Gateway endpoint is free and covers exactly this use case. Always prefer the Gateway endpoint:

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.default_main.id]
}
```

---

## IAM: least privilege in practice

The Glue role uses an inline scoped policy rather than broad managed policies like `AmazonS3FullAccess`. Each statement targets specific resources:

```
S3 → this bucket only (not s3:*)
DynamoDB → these 4 table ARNs only (not dynamodb:*)
Secrets Manager → this secret ARN only (not secretsmanager:*)
CloudWatch Logs → account-wide (logs don't contain sensitive data)
```

This matters in production because a misconfigured Glue job with `s3:*` can overwrite or delete any bucket in your account. Scoping to the specific bucket ARN limits the blast radius to the pipeline's own data.

The secret ARN in the IAM policy uses a `*` suffix — `${aws_secretsmanager_secret.rds_secret.arn}*` — because Secrets Manager appends a random 6-character suffix to the ARN when the secret is created. The base ARN alone won't match.

---

## S3 bucket layout

The bucket layout follows a **zone/domain/table/partition** structure that scales as you add more source systems:

```
s3://ntaccelerate-<suffix>/
├── glue_script/          ← ETL code (versioned with S3 versioning)
├── library/              ← shared Python libraries
├── raw/                  ← flat file landing zone
├── lake/
│   └── bronze/
│       └── tickit/       ← domain: one source system per prefix
│           ├── category/<run_date>/
│           ├── date/<run_date>/
│           ├── event/<run_date>/
│           ├── listing/<run_date>/
│           ├── sales/<run_date>/
│           ├── users/<run_date>/
│           └── venue/<run_date>/
├── sparkHistoryLogs/
└── temporary/
```

In a larger lake with multiple source systems, the structure would extend to `lake/bronze/<source_system>/<table>/<partition>/`. Keeping source systems namespaced prevents table name collisions (two different systems can both have a `users` table) and makes Lake Formation data permissions easier to apply at the domain level.

---

## What this would look like in a real production system

This lab uses a simplified setup that is good for learning but needs hardening for production:

| This lab | Production recommendation |
|----------|--------------------------|
| `db.t3.micro` SQL Server Express | RDS Multi-AZ, snapshot backups, encrypted storage |
| Public RDS endpoint | Private subnet, no public access, VPN or Direct Connect |
| Single AWS account | Separate accounts for dev/staging/prod (AWS Organizations) |
| Plain Parquet on S3 | Delta Lake or Iceberg for ACID, schema evolution, time travel |
| DynamoDB watermark state | Apache Airflow or Step Functions for orchestration with retry/alerting |
| Manual crawler trigger | Scheduled crawler or event-driven trigger on source change |
| Glue bookmark for deduplication | Explicit deduplication in the silver layer transformation |
| No data quality checks | Great Expectations or AWS Deequ on bronze output |
| `terraform.tfvars` on disk | Credentials in AWS Secrets Manager or Vault, not in files |
| AdministratorAccess for deployment | Scoped CI/CD role with only the permissions the pipeline needs |

The gap between "works in the lab" and "production-ready" is mostly about failure modes: what happens when the source is unavailable, when a schema changes, when a job runs twice, when credentials rotate. Day 2 and Day 3 of this series address some of these gaps — orchestration, error handling, and schema management.

---

## Cost

Running this stack in `us-east-1` for a lab session:

| Resource | Cost |
|----------|------|
| RDS db.t3.micro (provisioned ~2 hr) | ~$0.03 |
| Glue Crawler (5 min) | ~$0.17 |
| 7 Glue Jobs (~5 min each, G.1X × 2) | ~$0.50 |
| S3 storage + requests | < $0.01 |
| Secrets Manager | $0.013/day |
| **Single session total** | **~$0.75** |

The main ongoing cost risk is forgetting to stop RDS. At $0.017/hr it costs $12/month running continuously. Stop it immediately after use:

```bash
aws rds stop-db-instance --db-instance-identifier nt-accelerate-sqlserver
```

---

## Deployment quick-start

```bash
# 1. Prerequisites
brew install sqlcmd terraform awscli git-lfs

# 2. Pull the LFS-tracked seed file (246 MB)
git lfs pull --include="instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"

# 3. Configure AWS credentials
aws configure

# 4. Create terraform.tfvars — never commit this file
cat > infra/terraform.tfvars <<EOF
bucket_name          = "ntaccelerate-<your-unique-suffix>"
db_username          = "admin"
db_password          = "YourPass123!"
source_artifacts_dir = "../instruction/day1"
EOF

# 5. Deploy
cd infra && terraform init && terraform apply -auto-approve

# 6. Seed RDS (if the auto-seed skipped — check terraform output for null_resource errors)
python3 scripts/batch_seed.py \
  --server "$(terraform output -raw rds_endpoint | sed 's|jdbc:sqlserver://||;s|:1433.*||'),1433" \
  --user admin --password "YourPass123!" \
  --script "../instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"

# 7. Run crawler and jobs
aws glue start-crawler --name NT_Accelerate_cwl_RDSTickit
# wait ~5 min for crawler to finish, then:
for job in jb_Stg_Extract_Category jb_Stg_Extract_Date jb_Stg_Extract_Event \
           jb_Stg_Extract_Listing jb_Stg_Extract_Users jb_Stg_Extract_Venue; do
  aws glue start-job-run --job-name $job
done
aws glue start-job-run --job-name jb_Stg_Extract_Sales

# 8. Teardown
aws s3 rm s3://ntaccelerate-<suffix> --recursive
cd infra && terraform destroy -auto-approve
```

---

## What's next

Day 2 adds the orchestration and silver layer: a master Glue job that runs all extractions in sequence, Step Functions for retry logic, Lambda for failure notifications via SES, and silver layer transformations that clean, deduplicate, and conform the bronze Parquet into Delta tables.

Day 3 covers the gold layer: pre-aggregated business metrics in Parquet optimized for BI tools, and loading into Redshift for SQL-based analytics.

---

*This series is based on the AWS TechCamp 2022 Day 1–3 labs, rebuilt as Terraform for reproducibility and used as a teaching example for data lakehouse architecture on AWS.*
