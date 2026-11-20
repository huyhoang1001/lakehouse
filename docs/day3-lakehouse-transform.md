# Building a Data Lakehouse on AWS — Day 3: Transform & Serve

*Part 3 of a 3-part series on building a production-grade data lakehouse on AWS using Terraform.*

---

Day 1 landed raw data in S3. Day 2 wrapped the pipeline in an orchestrator so it runs without a human. Neither of them answered the question the business actually cares about: *can an analyst query this?*

Day 3 is the last mile. It takes the bronze Parquet that Day 1 wrote and turns it into two serving surfaces: a set of **Delta Lake** tables with ACID transactions and time travel, and an **Amazon Redshift** warehouse laid out as a star schema (`dim_*` and `fact_sales`). Both are driven by the two data-warehouse master jobs — `NT_Accelerate_LakeHouse_Master_Job` and `NT_Accelerate_RedshiftDW_Master_Job` — that the Day 2 module already deployed and left waiting for exactly this.

And, as with Day 1 and Day 2, all of it is Terraform. Day 3 lives in its own module (`infra/modules/day3/`) and never edits a file under `day1/` or `day2/` — it only consumes their outputs.

---

## What Day 3 adds

Day 2 made the *extraction* pipeline self-driving. Day 3 makes the *transformation and serving* layers self-driving the same way:

| Concern | Before Day 3 | Day 3 |
|---------|--------------|-------|
| Diagnosable storage | Raw Parquet, no transactions | **Delta Lake** — ACID, schema evolution, time travel |
| Serving layer | Query S3 through Athena | **Redshift** star schema (`dim_*`, `fact_sales`) |
| Transform jobs | Not deployed | 6 `jb_DW_Delta_Load_*` + 6 `jb_DW_Redshift_Load_*` |
| Warehouse | — | Redshift cluster, Glue JDBC connection, credential secret |
| Control-plane rows | Staging job only (`ID=1`) | `JOB_CONFIG` `ID=8–19`, `MASTER_JOB_CONFIG` `ID=2`, `ID=3` |
| Orchestration | Staging master job wired | The two Day 2 master jobs are now backed by real jobs |

The medallion architecture is finally complete — all three layers are populated by pipelines that share one control plane:

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
  Day 1              Delta Lake           Redshift
                     (lake/gold/tickit/)  (tickit)
                     └────────── Day 3 ──────────────┘
```

> A naming note. The Day 1 and Day 2 writeups distinguish "silver" (cleaned/conformed Delta) from "gold" (aggregated). In this lab the Delta jobs land their output under the module's gold path, `lake/gold/tickit/`, as a faithful 1:1 conform of the bronze Parquet — the heavier dimensional modelling (the actual star schema) happens in Redshift. If you extend the lab, the natural split is a silver Delta table per source table plus a gold aggregation on top; the module is structured so that is a matter of adding jobs and `JOB_CONFIG` rows, not new plumbing.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AWS us-east-1                                                           │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  S3: ntaccelerate-<suffix>                                        │   │
│  │   lake/bronze/tickit/<table>/<run_date>/   ← Day 1 (read)         │   │
│  │   lake/gold/tickit/<DeltaTable>/           ← Day 3 Delta output   │   │
│  │   library/delta-spark_2.13-4.1.0.jar       ← Day 3 runtime        │   │
│  │   temporary/                               ← Redshift COPY staging │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│            ↑ read bronze                    ↑ write Delta / COPY         │
│                                              │                           │
│  ┌──────────────────────────────────────┐   │                           │
│  │  AWS Glue (Spark, G.1X × 2)          │───┘                           │
│  │  Catalog DB: tickit                  │                               │
│  │  Connection: conRedshift_tickit ◄── sg_redshift_glue SG (5439)       │
│  │  Delta jobs   : jb_DW_Delta_Load_*    (6)                            │
│  │  Redshift jobs: jb_DW_Redshift_Load_* (6)                            │
│  └────────────┬─────────────────────────────────┬─────────────────────┘   │
│     write Delta│                               │ JDBC 5439                 │
│                ▼                               ▼                           │
│        s3://.../lake/gold/tickit/      ┌───────────────────────┐          │
│        (Delta Lake tables)             │  Amazon Redshift      │          │
│                                         │  dc2.large, db: tickit│          │
│                                         │  dim_* · fact_sales   │          │
│                                         │  sg_redshift SG       │          │
│                                         └───────────────────────┘          │
│  DynamoDB: JOB_CONFIG (+12) · MASTER_JOB_CONFIG (+ID 2, 3)               │
│  Secrets Manager: Redshift_Database_Connection_Info                      │
│  IAM: NT_Accelerate_GlueRole (+ Day3 policy)                             │
└─────────────────────────────────────────────────────────────────────────┘
```

Day 3 does **not** create the three Step Functions state machines. `infra/modules/day2/sfn.tf` already deploys `NT_Accelerate_LakeHouse_Master_Job` and `NT_Accelerate_RedshiftDW_Master_Job`, and those definitions already reference the twelve `jb_DW_*` job names verbatim. Day 3's job is to make those references real: create the jobs, the targets they write to, and the control-plane rows that tell the orchestrator how to run them.

---

## Design decisions worth explaining

### Why Delta Lake for the transform layer?

The bronze layer is plain Parquet — good enough for "store what the source had," but it has no transaction log. If a job half-writes a directory and fails, you have a corrupt partition and no way to roll back. Delta Lake adds a transaction log (`_delta_log/`) on top of the Parquet files, which buys three things:

- **Atomic commits.** A write either fully lands or not at all. A failed job never leaves a half-written table.
- **Schema evolution.** The Delta job writes with `overwriteSchema=true`, so a new column in the source lands without an operator dropping the table first.
- **Time travel.** `SELECT * FROM delta.\`path\` VERSION AS OF 3` lets you query a prior commit — invaluable when you need to explain what a dashboard showed yesterday.

The tradeoff is a runtime dependency: Delta is not part of Glue's default Spark, so the job needs the Delta jar on the classpath (`--extra-jars`) and the Delta `SparkSession` extension registered in `--conf`.

### Why Redshift as well as Delta?

Delta on S3 is a great lake format; it is not a great multi-user BI warehouse. Redshift gives you columnar MPP compute, materialised statistics (`ANALYZE`), concurrency scaling, and a familiar star schema for the SQL tools analysts already use. Loading the same data into both surfaces is the "lakehouse" bet: cheap open storage for data science and Spark, a tuned warehouse for BI.

The star schema the Redshift jobs build is conventional:

```
        dim_date   dim_venue   dim_category
              \         |          /
               \        |         /
   dim_user ────────────┼─────────────── fact_sales
               /        |         \
        dim_event ──────┘          (measures)
```

Six jobs, one per table — the same six source tables Day 1 extracted.

### Why let Day 2 own the orchestrator and have Day 3 only fill the gaps?

The cleanest layering decision in Day 3 is what it *doesn't* do. The orchestrator (Step Functions, Lambda, the run-mode logic) is a Day 2 concern and is deployed once, verbatim. Day 3 adds zero orchestration code. Instead it satisfies the contract the Day 2 master jobs already expect:

1. **Glue jobs with the exact names** the state machine references (`jb_DW_Delta_Load_DateDim` … `jb_DW_Redshift_Load_SalesFact`).
2. **`JOB_CONFIG` rows** so `NT_Accelerate_Is_Allow_Running` can resolve each job's parameters.
3. **`MASTER_JOB_CONFIG` rows** `ID=2` and `ID=3` so `NT_Accelerate_Read_Run_Type` can start the LakeHouse and RedshiftDW master jobs at all.

This is why Day 3 can add two entire pipeline stages without touching a single line of orchestration code. The contract between the layers is data (job names and table rows), not code.

### Why does the same `JOB_CONFIG` table drive three different job shapes?

`NT_Accelerate_Is_Allow_Running` serves every layer through one table by branching on a `LAYER` column, which decides which columns it bothers to read:

```
LAYER == "STAGING"    → clears catalog_con, uses INCREMENTAL_LOAD       (Day 1 jobs)
LAYER == "LAKEHOUSE"  → uses LAKEHOUSE_LOCATION, clears catalog/scripts (Delta jobs)
else (i.e. "DW")      → uses CATALOG_CON, PRESCRIPT, POSTSCRIPT, TEMP_FOLDER (Redshift jobs)
```

Day 3 writes its Delta rows with `LAYER=LAKEHOUSE` (populating `LAKEHOUSE_LOCATION`, blanking the Redshift fields) and its Redshift rows with `LAYER=DW` (the mirror image). Every row still carries the **full superset** of columns, because the Lambda projects all of them — a missing key would raise a `KeyError` and fail the run before the job even starts.

### Why a Glue connection, a self-referencing security group, and a secret?

A Glue job writing to Redshift is a JDBC client running on ENIs inside your VPC. Three things have to line up, and each one is a classic first-day setup trap:

1. **The connection** (`conRedshift_tickit`) carries the JDBC URL and credentials, and pins the ENIs to a subnet and security group.
2. **Networking.** The Glue connection's SG needs the self-referencing ingress rule (driver ↔ executor traffic over the ENIs) — the same rule Day 1 needed for its RDS connection. The cluster's SG then allows port 5439 *from* the Glue SG, not from `0.0.0.0/0`.
3. **Credentials.** The JDBC user/password live in Secrets Manager (`Redshift_Database_Connection_Info`) rather than in `JOB_CONFIG`, so they never appear in job parameters, the console, or CloudTrail. The Glue role gets `GetSecretValue` on that secret ARN only.

### Why gate Redshift behind an `enable_redshift` flag?

A `dc2.large` cluster bills hourly, whether or not anyone queries it. So the entire Redshift half of Day 3 — cluster, subnet group, security groups, connection, secret, and the six Redshift jobs and their config rows — is gated by a single variable:

```hcl
enable_redshift = true   # false ⇒ Delta-only apply, no Redshift resources at all
```

Every Redshift resource uses `count = var.enable_redshift ? 1 : 0` (or an empty `for_each`), so a Delta-only run creates nothing that bills by the hour. Tear down is `skip_final_snapshot = true`, so `terraform destroy` is clean.

### Why keep logging the same way as Day 1?

Both Day 3 scripts call the same `Genericlib.WriteLog` / `Genericlib.UpdateJobStatus` helpers the Day 1 extraction jobs use: append a row to `NT_Accelerate_JOB_LOG` and upsert the latest status into `NT_Accelarate_JOB_STATUS`. That consistency is what makes the Day 2 control plane work unchanged — `Is_Allow_Running` and the RERUN logic find Day 3 jobs in exactly the same tables as Day 1 jobs, with no per-layer special-casing.

> **A note on the typos (again).** `NT_Accelarate_JOB_STATUS` (missing an `e`) and `NT_Acccelarate_WATERMARKTABLE` (triple `c`, missing an `e`) are spelled that way in the original lab. Day 3 references them verbatim — the module's `locals.tf` carries a do-not-fix comment. Correcting the spelling breaks every job at runtime with `ResourceNotFoundException`.

---

## The Day 3 job inventory

Twelve Glue jobs, six per layer. Job names match the Step Functions definitions exactly.

| Glue job | Bronze source | Target | Layer |
|----------|---------------|--------|-------|
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

### How the Delta job works

`jb_DW_Delta_Load.py` is deliberately small:

1. Read the bronze Parquet for `--p_src_tableName` (`spark.read.parquet`).
2. Write it as a Delta table at `<--p_lakehouse_location>/<--p_tar_tablename>` with `mode("overwrite")` and `overwriteSchema=true`.
3. Log `SUCCEEDED`/`FAILED` to `JOB_LOG` and `JOB_STATUS` via `Genericlib`.

The bronze path is derived from the gold location the master job passes — `s3://<bucket>/lake/gold/tickit/` — by swapping `/lake/gold/` for `/lake/bronze/`. So the job needs only the arguments the orchestrator already sends; there is no second path to keep in sync.

### How the Redshift job works

`jb_DW_Redshift_Load.py` reads the same bronze Parquet, converts it to a Glue `DynamicFrame`, and writes it through the Glue connection:

```python
connection_options = {"dbtable": var_tar_table, "database": var_tar_db}
if var_prescript:  connection_options["preactions"]  = var_prescript
if var_postscript: connection_options["postactions"] = var_postscript

glueContext.write_dynamic_frame.from_jdbc_conf(
    frame=dfSource,
    catalog_connection=var_catalog_con,          # "conRedshift_tickit"
    connection_options=connection_options,
    redshift_tmp_dir=var_redshift_temp,          # s3://<bucket>/temporary/
    transformation_ctx="redshift_datasink",
)
```

`preactions` / `postactions` come straight from the job's `JOB_CONFIG` row — Terraform seeds `drop table if exists <table>` and `analyze <table>` — so the load is idempotent and statistics are refreshed after each run.

---

## The control plane: what Day 3 writes

Two tables Day 1/Day 2 already own get twelve new rows. Neither table is created by Day 3 — it only adds items.

### `NT_Accelerate_JOB_CONFIG` — IDs 8–19

| Attribute | Delta rows (8–13) | Redshift rows (14–19) |
|-----------|-------------------|------------------------|
| `JOB_NAME` | `jb_DW_Delta_Load_*` | `jb_DW_Redshift_Load_*` |
| `LAYER` | `LAKEHOUSE` | `DW` |
| `MULTIPLE_RUN` | `FALSE` | `FALSE` |
| `SRC_DBNAME` / `SRC_TBLNAME` | `tickit` / bronze table | `tickit` / bronze table |
| `TRG_DBNAME` / `TRG_TBLNAME` | gold path / `DateDim`… | `tickit` / `dim_date`… |
| `LAKEHOUSE_LOCATION` | gold path | `""` |
| `CATALOG_CON` | `""` | `conRedshift_tickit` |
| `PRESCRIPT` / `POSTSCRIPT` | `""` | `drop table if exists …` / `analyze …` |
| `TEMP_FOLDER` | `""` | `s3://<bucket>/temporary/` |

`MULTIPLE_RUN=FALSE` means each job runs at most once per day — the Day 2 `Check_Job_Ran_In_Day` dedup applies to Day 3 jobs exactly as it does to Day 1's.

### `NT_Accelerate_MASTER_JOB_CONFIG` — IDs 2 and 3

| ID | Master job | Seed |
|----|-----------|------|
| `2` | `NT_Accelerate_LakeHouse_Master_Job` | `RUN_TYPE=NEW, RERUN_DATE=2024-01-01, BATCH_ID=0, LAST_RUN_DATE=2024-01-01, LAST_RUN_STATUS=NEW` |
| `3` | `NT_Accelerate_RedshiftDW_Master_Job` | same shape |

Day 2 owns `ID=1` (the staging job) and Day 3 does not touch it. `NT_Accelerate_Read_Run_Type` queries by `ID`, so a missing row would make the master job fail immediately at `Stop because of not configure yet`.

---

## Run order — and the staging gate

The three master jobs must run in order. `NT_Accelerate_LakeHouse_Master_Job` and `NT_Accelerate_RedshiftDW_Master_Job` both call `NT_Accelerate_Check_Staging_Master_Job_Status` before doing anything in `NEW` mode: it returns `flag=true` only if `MASTER_JOB_CONFIG` shows the staging job last succeeded for the requested run date. Start a downstream master job too early and it fails fast, by design.

```
1. Staging     NT_Accelerate_Datalake_Master_Job     (ID=1, Day 2)   RDS → bronze Parquet
2. LakeHouse   NT_Accelerate_LakeHouse_Master_Job    (ID=2)          bronze → Delta (gold)
3. RedshiftDW  NT_Accelerate_RedshiftDW_Master_Job   (ID=3)          bronze → Redshift tickit
```

```bash
SM_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='NT_Accelerate_LakeHouse_Master_Job'].stateMachineArn" \
  --output text)
aws stepfunctions start-execution --state-machine-arn "$SM_ARN"
```

To retry only what failed, set `RUN_TYPE=RERUN` on the relevant `MASTER_JOB_CONFIG` row (see the [Day 2 doc](./day2-orchestration.md)) and start the execution again — `Is_Allow_Running` deletes the `FAILED` status row and reruns just that job.

---

## IAM: least privilege, still

Day 3 does not create a new IAM role. It attaches one inline policy (`NT_Accelerate_GlueRole_Day3Policy`) to the **existing** Day 1 Glue role, scoped to the transform paths:

```
S3            → ListBucket on the bucket
                GetObject on lake/bronze/* and temporary/*      (read the sources)
                PutObject, DeleteObject on lake/gold/* and temporary/*  (Delta write + COPY staging)
Glue Catalog  → Get/Create/Update table + partition actions
Secrets       → GetSecretValue on the Redshift secret ARN only   (when enable_redshift)
```

The role keeps its Day 1 grants (S3 access to the bucket for extraction, the RDS secret) — Day 3 only *adds* a dedicated, narrowly scoped policy. The Redshift secret statement is built with a splat over `aws_secretsmanager_secret.redshift_secret[*].arn` so the policy stays valid when `enable_redshift = false` and the secret does not exist.

---

## Infrastructure as Code — module layout

Day 3 is a sibling module, wired by the same thin root as Day 1 and Day 2:

```
infra/
├── main.tf          — module.day1 → module.day2 → module.day3
│                      (Day 1 outputs feed Day 2; Day 1 + Day 2 outputs feed Day 3)
├── variables.tf     — root inputs, shared across the three modules
├── outputs.tf       — re-exports the interesting outputs from all three days
├── providers.tf     — AWS provider + default tags
├── versions.tf      — version pins
├── modules/
│   ├── day1/        — ingestion layer (unchanged)
│   ├── day2/        — orchestration layer (unchanged)
│   └── day3/        — transform + serving layer
│       ├── locals.tf      — table names (with typo comments), job inventory, S3 paths
│       ├── s3.tf          — gold Delta prefix + Delta runtime jar
│       ├── glue_jobs.tf   — 12 Glue jobs + script uploads
│       ├── glue.tf        — conRedshift_tickit JDBC connection
│       ├── redshift.tf    — cluster, subnet group, security groups (gated)
│       ├── secrets.tf     — Redshift credential secret (gated)
│       ├── iam.tf         — Day 3 inline policy on the Day 1 Glue role
│       ├── dynamodb.tf    — 12 JOB_CONFIG rows + 2 MASTER_JOB_CONFIG rows
│       ├── scripts/
│       │   ├── jb_DW_Delta_Load.py
│       │   └── jb_DW_Redshift_Load.py
│       └── outputs.tf     — job names, gold location, Redshift endpoint/connection
```

No remote state is involved: `module.day1` and `module.day2` expose their outputs, and the root feeds them straight into `module.day3`. The one cross-module subtlety: the Day 3 policy needs the Glue role **name**, but Day 1 only exports its ARN, so the root derives the name with `element(split("/", module.day1.glue_role_arn), 1)` — cheaper than reaching into the Day 1 module.

---

## Cost

Day 3 has one billable resource that is not pay-per-use: the Redshift cluster.

| Resource | Cost |
|----------|------|
| Redshift `dc2.large` × 1 | ~$0.25/hr while running |
| Delta jar (S3) | negligible |
| 12 Glue jobs (~2 min each, G.1X × 2) | ~$0.60 per full run |
| Glue Data Catalog, Secrets Manager | < $0.02/day |
| **Delta-only apply (`enable_redshift = false`)** | **~$0** |

**Stop the cluster when you are not using it.** Either set `enable_redshift = false` and re-apply, or `terraform destroy`. Because `skip_final_snapshot = true`, teardown leaves nothing behind to keep paying for.

---

## Known risk: the Delta jar ABI

The single highest-risk item in Day 3 is a version-matching problem, not a logic problem. The provided `delta-spark_2.13-4.1.0.jar` is built for **Scala 2.13 / Spark 4.x**, while Glue 3.0 ships **Spark 3.x / Scala 2.12**. A binary ABI mismatch shows up at runtime as `NoSuchMethodError` / `ClassNotFoundException` when the Delta extension loads — the job starts, then fails immediately.

Before running the Delta jobs end to end, either confirm the jar and the Glue version agree, or substitute a Glue-compatible Delta build (and pin `glue_version` accordingly). The Redshift jobs have no such dependency — they only need the JDBC connection and the AWS Glue Redshift driver.

---

## Deployment quick-start

Day 3 is applied through the **root** module, after Day 1 and Day 2.

```bash
# 1. Add the Day 3 inputs to infra/terraform.tfvars
cat >> infra/terraform.tfvars <<'EOF'
enable_redshift              = true
redshift_database_name       = "tickit"
redshift_master_username     = "admin"
redshift_master_password     = "MyPass123!"   # sensitive — gitignored
redshift_node_type           = "dc2.large"
redshift_number_of_nodes     = 1
redshift_publicly_accessible = false
EOF

# 2. Apply (creates Day 3 alongside Day 1 + Day 2)
cd infra && terraform init && terraform apply -auto-approve

# 3. Run the three master jobs in order
for name in NT_Accelerate_Datalake_Master_Job \
            NT_Accelerate_LakeHouse_Master_Job \
            NT_Accelerate_RedshiftDW_Master_Job; do
  ARN=$(aws stepfunctions list-state-machines \
    --query "stateMachines[?name=='$name'].stateMachineArn" --output text)
  aws stepfunctions start-execution --state-machine-arn "$ARN"
done

# 4. Verify (see below), then tear down — Redshift bills hourly
cd infra && terraform destroy -auto-approve
```

### Verification

- **Delta gold:** `s3://<bucket>/lake/gold/tickit/<table>/_delta_log/` exists for all six Delta tables.
- **Redshift:** the six tables exist in the `tickit` database with the expected row counts:
  ```bash
  aws redshift-data execute-statement \
    --cluster-identifier nt-accelerate-redshift --database tickit \
    --db-user admin --sql "select count(*) from fact_sales;"
  ```
- **Run records:** `NT_Accelerate_JOB_LOG` and `NT_Accelarate_JOB_STATUS` (note the intentional misspelling) show `SUCCEEDED` for all twelve Day 3 jobs, with no unresolved `FAILED` rows.
- **Control plane smoke tests:**
  ```bash
  aws lambda invoke --function-name NT_Accelerate_Read_Run_Type \
    --payload '{"p_masterjob_id": 2}' --region us-east-1 out.json

  aws lambda invoke --function-name NT_Accelerate_Is_Allow_Running \
    --payload '{"p_job_name": "jb_DW_Delta_Load_DateDim", "p_run_date": "2024-01-01", "p_run_type": "NEW"}' \
    --region us-east-1 out.json
  ```

---

## What this would look like in a real production system

| This lab | Production recommendation |
|----------|--------------------------|
| Single-node `dc2.large`, publicly accessible | Multi-node cluster in private subnets, `RA3` for managed storage |
| Static Dimension/Fact counts | Iceberg/Delta native Redshift Spectrum for the whole lake |
| Console/CLI start of master jobs | EventBridge schedule chained on the staging job's success |
| Glue role with catalog `*` actions | Lake Formation table permissions + column-level masking for PII |
| `--conf` Delta settings inline in the job | Job-level dependency management (Glue Studio or a runtime catalog) |
| `skip_final_snapshot = true` | Off-hours snapshot + restore drill before teardown |
| No data-quality gates | Great Expectations / AWS Deequ between bronze and serving |
| Manual Redshift credential rotation | Secrets Manager rotation Lambda wired to the cluster |

The gap between "works in the lab" and "production-ready" is, one more time, mostly failure modes — but by Day 3 the pipeline has the hooks to handle them: every job reports status, every layer is gated on the one before it, and every rerun is targeted rather than wholesale.

---

## Wrapping up the series

Three days, three layers, one control plane:

- **Day 1** made the data *available* — RDS Tickit extracted to bronze Parquet.
- **Day 2** made the pipeline *autonomous* — master jobs, run modes, notifications.
- **Day 3** made the data *answerable* — Delta Lake and a Redshift star schema, fed by the same orchestrator that has been waiting for them since Day 2.

The through-line across all three days is the same: keep the layers decoupled (each reads the one before it through data, not code), keep the control plane in one place (DynamoDB), and describe all of it in Terraform so the whole thing can be stood up, torn down, and rebuilt identically.

---

*This series is based on the AWS TechCamp 2022 Day 1–3 labs, rebuilt as Terraform for reproducibility and used as a teaching example for data lakehouse architecture on AWS.*
