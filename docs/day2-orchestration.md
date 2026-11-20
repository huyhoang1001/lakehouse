# Building a Data Lakehouse on AWS — Day 2: Orchestration Layer

*Part 2 of a 3-part series on building a production-grade data lakehouse on AWS using Terraform.*

---

Day 1 got raw data out of SQL Server and into S3 as Parquet. That pipeline works, but it is manual: you run the crawler, then you kick off seven Glue jobs by hand, and you watch them in the console to see which ones failed. That is fine for a demo and useless for anything that has to run every night.

This post is about the control plane. Day 2 wraps the Day 1 extraction jobs in a set of **master jobs** — AWS Step Functions state machines that decide, per run, whether each Glue job should run, be skipped (it already ran today), or be retried (it failed in the last run). Nine AWS Lambda functions make every one of those decisions against a DynamoDB control plane, and an HTML status email goes out through Amazon SES when the run finishes.

As in Day 1, everything is provisioned with Terraform. Day 2 lives in its own module and never touches a Day 1 resource definition — it only reads Day 1's outputs.

---

## What Day 2 adds

Day 1 answered "how do we get the data out?". Day 2 answers "how do we run the pipeline without a human, and how do we know what happened?". Concretely:

| Concern | Day 1 | Day 2 |
|---------|-------|-------|
| Trigger | Manual (`aws glue start-job-run`) | Step Functions master job (manual, or daily via EventBridge) |
| Ordering & parallelism | You run jobs one at a time | 7 jobs run in parallel branches |
| Retry of failures | You re-run whatever failed, by hand | `RERUN` mode retries only the failed jobs |
| Duplicate protection | None — re-running re-extracts | `NEW` mode skips jobs that already succeeded today |
| Failure visibility | Console + CloudWatch logs | HTML summary email via SES |
| Configuration | Hardcoded job parameters | DynamoDB control tables |

The medallion architecture is unchanged — Day 2 is the orchestration layer that sits *around* the pipeline rather than moving data itself:

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
  Day 1 + ───────────► orchestration ───────────►
  Day 2               (Step Functions · Lambda · DynamoDB · SES)
```

Day 2 provisions three master jobs in total. Only the first — the staging master job that drives the seven Day 1 extraction jobs — is fully wired with parallel branches today. The other two (`LakeHouse` and `RedshiftDW`) are provisioned now so the silver and gold jobs that Day 3 builds can plug into the same control pattern without a rewrite.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AWS us-east-1                                                           │
│                                                                          │
│  EventBridge (optional daily cron) ─────────┐                            │
│                                             ▼                            │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Step Functions — 3 STANDARD state machines                       │   │
│  │   NT_Accelerate_Datalake_Master_Job    ← 7 parallel Glue branches │   │
│  │   NT_Accelerate_LakeHouse_Master_Job   ← silver layer (Day 3)     │   │
│  │   NT_Accelerate_RedshiftDW_Master_Job  ← gold layer  (Day 3)      │   │
│  └───────────────┬──────────────────────────────────────────────────┘   │
│                  │ invoke                                                │
│  ┌───────────────▼──────────────────────────────────────────────────┐   │
│  │  Lambda — 9 orchestration functions (`NT_Accelerate_*`)           │   │
│  │   Read_Run_Type · Check_Job_Status · Truncate_Job_Status          │   │
│  │   Is_Allow_Running · Check_Job_ReRun · Update_Job_Status          │   │
│  │   Update_MasterJob_Status · Check_Staging_Master_Job_Status       │   │
│  │   Send_Mail                                                        │   │
│  └───────────────┬──────────────────────────────────────────────────┘   │
│                  │ read/write                                            │
│  ┌───────────────▼──────────────────────────────────────────────────┐   │
│  │  DynamoDB — 6 control tables                                      │   │
│  │   NT_Accelerate_MASTER_JOB_CONFIG   ← new (Day 2)                 │   │
│  │   NT_Accelerate_Mail_Config         ← new (Day 2)                 │   │
│  │   NT_Accelerate_JOB_CONFIG          ← extended by Day 2           │   │
│  │   NT_Accelerate_JOB_LOG             ← Day 1, read-only            │   │
│  │   NT_Accelarate_JOB_STATUS          ← Day 1, read/write           │   │
│  │   NT_Acccelarate_WATERMARKTABLE     ← Day 1, read-only            │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  SES: sender + receiver email identities (must be verified in sandbox)  │
│  IAM: NT_Accelerate_LambdaRole · NT_Accelerate_StepFunctionsRole         │
│       NT_Accelerate_EventBridgeRole (only when the schedule is enabled)  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Day 1 stack (unchanged) — S3 · Glue jobs · RDS · Networking      │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Design decisions worth explaining

### Why Step Functions as the orchestrator?

The Day 1 pipeline is a DAG: extract seven tables, then notify. That is exactly what a Step Functions state machine is for, and it brings three things a cron script does not:

- **`startJobRun.sync`.** The `states:::glue:startJobRun.sync` integration waits for a Glue job to finish and returns its result. You get completion without polling.
- **Retry with backoff, declaratively.** Every task state retries `Lambda.ServiceException` / `Lambda.AWSLambdaException` / `Lambda.SdkClientException` up to 6 times with `IntervalSeconds: 2` and `BackoffRate: 2`. That is a three-line `Retry` block, not a retry framework.
- **A visual execution history.** When a run fails, the console shows exactly which branch failed and the input/output at every step.

The alternative — Airflow or a scheduled Lambda — is a fine choice in a bigger shop. Step Functions wins here because it is serverless, has no cluster to operate, and bills per state transition.

### Why two run modes, NEW and RERUN?

The single most common operational task on a batch pipeline is "one job failed last night, re-run just that job". If the only mode you have is "run everything", you either re-extract tables that already succeeded (wasting time and producing duplicate bronze output) or you drop back to the console and run the one job by hand (defeating the point of the orchestrator).

So the master job reads a `RUN_TYPE` from a control table:

- **`NEW`** — a fresh daily run. The state machine checks `JOB_STATUS` for unresolved failures first. If any exist, it records `LAST_RUN_STATUS=FAILED` and stops *without* running anything, so you don't stack a new batch on top of a broken one. If the slate is clean, it deletes all `JOB_STATUS` rows and runs.
- **`RERUN`** — a targeted retry. It skips the status check and goes straight to the parallel branches, where each job decides for itself whether it needs to run based on its own entry.

This is the same idea as the Day 1 watermark: keep enough state to avoid doing work you have already done.

### Why Lambda for every decision?

Each "should this job run?" question is a small, well-defined DynamoDB query. A Lambda is the smallest thing that can answer it. The Step Functions definition stays readable — each branch is "ask Lambda, branch on the answer, then either start the Glue job or mark it already-done" — and the decision logic lives in testable Python instead of being buried in state-machine JSON.

The tradeoff is more moving parts (nine functions), but each one is tiny and the alternative — encoding the DynamoDB logic directly in Step Functions with `DynamoDB` service integrations — is far harder to read and change.

### Why deploy the Lambda code verbatim, and only substitute the ARNs?

The Lambda functions and the Step Functions JSON come straight from the original lab artifacts. Day 2 deploys them **unchanged** — Terraform only packages and wires them; it does not rewrite Python. The single exception is the state-machine JSON, which has the lab's AWS account ID (`377414509754`) hardcoded into every Lambda invoke ARN (that fragment appears *only* inside those ARNs). Terraform rewrites those two strings at apply time:

```hcl
replace(
  replace(file(path),
    "arn:aws:lambda:us-east-1:377414509754:function:",
    "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:",
  ),
  ":$LATEST", "",
)
```

The `:$LATEST` qualifier is stripped too, because the deployed functions have no versioned alias. This means the same JSON deploys to any account, which is the whole point of Infrastructure as Code.

---

## The control plane: DynamoDB tables

Six tables drive the orchestration. Two are new in Day 2; the other four are Day 1 tables that Day 2 reads (and, for `JOB_STATUS`, writes).

| Table | Owner | Purpose |
|-------|-------|---------|
| `NT_Accelerate_MASTER_JOB_CONFIG` | Day 2 | Run type, rerun date, batch ID, last run status per master job |
| `NT_Accelerate_Mail_Config` | Day 2 | SES sender and receiver addresses |
| `NT_Accelerate_JOB_CONFIG` | Day 1 (extended by Day 2) | Per-Glue-job parameters read by `Is_Allow_Running` |
| `NT_Accelerate_JOB_LOG` | Day 1 | Historical run records per job (read to detect "already ran today") |
| `NT_Accelarate_JOB_STATUS` | Day 1 | Current run status per job (`SUCCEEDED` / `FAILED`) |
| `NT_Acccelarate_WATERMARKTABLE` | Day 1 | Incremental watermark for the Sales job |

> **A note on the typos.** `NT_Accelarate_JOB_STATUS` (missing an `e`) and `NT_Acccelarate_WATERMARKTABLE` (triple `c`, missing an `e`) are spelled that way in the original lab and are referenced verbatim by the Lambda code. They are **deliberate**. Terraform defines them in `locals` with a comment forbidding correction — a "helpful" fix makes every Lambda fail with `ResourceNotFoundException`.

### Master job configuration

`NT_Accelerate_MASTER_JOB_CONFIG` is keyed by `ID` (numeric); row `ID=1` is the staging master job. Its seed row is:

| Attribute | Value | Notes |
|-----------|-------|-------|
| `ID` | `1` | 1 = staging, 2 = LakeHouse, 3 = RedshiftDW |
| `RUN_TYPE` | `NEW` | `NEW` or `RERUN` |
| `RERUN_DATE` | `2024-01-01` | Date used as `run_date` when `RUN_TYPE=RERUN` |
| `BATCH_ID` | `0` | Incremented on every `NEW` run |
| `LAST_RUN_DATE` | `2024-01-01` | Written by `Update_MasterJob_Status` |
| `LAST_RUN_STATUS` | `NEW` | `SUCCEEDED` or `FAILED` |

To start a normal run you leave the row as-is. To retry only what failed, set `RUN_TYPE=RERUN` and `RERUN_DATE` to the date you want to retry:

```bash
aws dynamodb update-item \
  --table-name NT_Accelerate_MASTER_JOB_CONFIG \
  --key '{"ID":{"N":"1"}}' \
  --update-expression "SET RUN_TYPE=:t, RERUN_DATE=:d" \
  --expression-attribute-values '{":t":{"S":"RERUN"},":d":{"S":"2024-01-01"}}'
```

### Mail configuration

`NT_Accelerate_Mail_Config` holds a single row (`ID=1`) with a `SENDER` and a `RECEIVER` list. The seed values come from the two root variables `ses_sender_email` and `ses_receiver_emails`, so you configure them once in `terraform.tfvars`. Note the `ID` key is a **string** here (the `Send_Mail` Lambda scans with `ID = "1"`), unlike `MASTER_JOB_CONFIG`'s numeric key.

### Extending JOB_CONFIG

Day 2 rewrites each of the seven `NT_Accelerate_JOB_CONFIG` rows with a superset of columns: every Day 1 column is preserved, and the Day 2 columns (`LAYER`, `MULTIPLE_RUN`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `POSTSCRIPT`, `PRESCRIPT`, `TEMP_FOLDER`) are added so `Is_Allow_Running` can read every field it needs without a `KeyError`. The rows are written with `lifecycle { ignore_changes = [] }` to record that the Lambdas — not Terraform — own the values at runtime.

---

## How the master job works

### Staging master job flow

```
StartAt: Read run_type from MASTER JOB CONFIG table
    │
    ▼
Choice: flag == true?
    ├── false → Fail: "Stop because of not configure yet"
    └── true  →
            Choice: run_type == NEW or RERUN?
            ├── RERUN → Run jobs in parallel
            └── NEW   →
                    Check JOB STATUS table
                        │
                        ▼
                    Choice: FailedJobExisting?
                    ├── true  → Update_MasterJob_Status(FAILED) → Fail
                    └── false → Truncate table JOB_STATUS
                                    │
                                    ▼
                            Run jobs in parallel (7 branches)
                                    │
                                    ▼ (all branches complete)
                            Update_MasterJob_Status(SUCCEEDED)
                                    │
                                    ▼
                            Send mail
                                    │
                                    ▼
                                  End
```

One detail worth calling out: if a parallel Glue branch fails, the `Parallel` state's `Catch` block routes to `Update Master Job Failed for failed job` → `Send Mail for Staging Jobs failed`. So the failure path emails the operator and marks the master job `FAILED` instead of leaving the run in limbo.

### The per-job branch

Every one of the seven parallel branches has the same shape:

```
Is_Allow_Running(p_job_name, p_run_date, p_run_type)
    │
    ▼
Choice: is_ran == "Yes"?
├── Yes → Update_Job_Status(SUCCEEDED) → End   (skip: already ran today)
└── No  → Glue startJobRun.sync(job_name, args from Is_Allow_Running) → End
```

`Is_Allow_Running` is the brain of the whole thing. It returns `is_ran=Yes` / `No` plus the full set of Glue job parameters, and its answer depends on the run mode:

| Scenario | Result |
|----------|--------|
| `MULTIPLE_RUN=FALSE`, `RUN_TYPE=NEW`, job already in `JOB_LOG` for today | `is_ran=Yes` — skip |
| `RUN_TYPE=RERUN`, job in `JOB_STATUS` as `FAILED` | delete the row, `is_ran=No` — rerun |
| `RUN_TYPE=RERUN`, job in `JOB_STATUS` as `SUCCEEDED` | `is_ran=Yes` — skip |
| `RUN_TYPE=RERUN`, no `JOB_STATUS` row | `is_ran=No` — run |

When it returns `No`, the state machine starts the Glue job with `startJobRun.sync` and passes the parameters straight from the Lambda response — the extraction jobs are unchanged; they just get their arguments from the orchestrator now instead of from a human.

### The two Day 3 gates

Two of the nine Lambdas do not appear in the staging flow:

- **`Check_Job_ReRun`** — a reusable predicate for whether a given job should rerun.
- **`Check_Staging_Master_Job_Status`** — given a `run_date`, returns `{"flag": true}` only if `MASTER_JOB_CONFIG` shows `LAST_RUN_DATE` = that date and `LAST_RUN_STATUS=SUCCEEDED`. This is the gate the LakeHouse and RedshiftDW master jobs will use to confirm staging succeeded before they start.

Both are deployed and invokable now so Day 3 can wire them in without new infrastructure.

---

## SES notifications

When the run finishes, `Send_Mail` reads the sender and receiver from `Mail_Config`, queries `JOB_STATUS` for every `SUCCEEDED`/`FAILED` row, and sends an HTML table with `JOB_NAME`, `PROCESS_STATUS`, `RUN_DATE`, and `ERROR_MSG`. If the table would be empty, it returns without sending.

**Sandbox caveat.** A new SES account is in the sandbox, where both the sender and every receiver must be verified before any mail is delivered:

1. Terraform creates the identities (`aws_ses_email_identity`) for the sender and each receiver, which sends a verification email to each address.
2. **Each address owner must open that email and click the link.** Terraform cannot do this step.
3. Only then will `Send_Mail` include an address. The Lambda calls `ses:GetIdentityVerificationAttributes` and silently drops any address that is not `Success`, so an unverified recipient is skipped rather than failing the run.

---

## IAM: least privilege in practice

Two roles (a third is created only when the schedule is enabled), each with an inline scoped policy and no AWS managed policies:

```
NT_Accelerate_LambdaRole        trust: lambda.amazonaws.com
  DynamoDB  → CRUD on the 6 control tables only
  Glue      → StartJobRun, GetJobRun on job/*
  SES       → SendEmail, GetIdentityVerificationAttributes
  Logs      → CreateLogGroup, CreateLogStream, PutLogEvents

NT_Accelerate_StepFunctionsRole trust: states.amazonaws.com
  Lambda    → InvokeFunction on the 9 orchestration functions only
  Glue      → StartJobRun, GetJobRun on job/*
  Logs      → log-delivery permissions for Step Functions logging

NT_Accelerate_EventBridgeRole   trust: events.amazonaws.com   (schedule only)
  States    → StartExecution on the staging master job ARN only
```

The point is the same as Day 1: a misconfigured orchestrator should be able to break its own tables and jobs, and nothing else. The Step Functions role can invoke exactly nine named functions — not every Lambda in the account.

---

## Infrastructure as Code — module layout

After the Day 1 stack, the repository was restructured so the two days are sibling modules wired together by a thin root:

```
infra/
├── main.tf          — module.day1 → module.day2 (Day 1 outputs passed in directly)
├── variables.tf     — inputs for both modules
├── outputs.tf       — re-exports the Day 1 outputs
├── providers.tf     — AWS provider + default tags
├── versions.tf      — version pins
├── modules/
│   ├── day1/        — extraction layer (unchanged)
│   └── day2/        — orchestration layer
│       ├── lambda.tf      — 9 archive_file + s3_object + lambda_function
│       ├── sfn.tf         — 3 state machines + ARN substitution + log groups
│       ├── dynamodb.tf    — 2 new tables + seed items + JOB_CONFIG rewrite
│       ├── iam.tf         — Lambda + Step Functions roles
│       ├── ses.tf         — sender + receiver identities
│       └── eventbridge.tf — optional daily schedule
```

The design originally called for Day 2 to read Day 1 through remote state. The restructure made that unnecessary: `module.day1` exposes its outputs and the root feeds them straight into `module.day2`, so there is no second state file to keep in sync.

Each Lambda is packaged with `archive_file` (ZIP written to the repo-root `tmp/`) and uploaded to `s3://<bucket>/lambda/<function>.zip`; the function's `source_code_hash` is the archive hash, so editing a `.py` file and re-applying redeploys it automatically.

### The optional schedule

An EventBridge rule (`cron(0 8 * * ? *)`, daily at 08:00 UTC) can start the staging master job automatically. It is off by default and gated by one variable:

```hcl
enable_schedule = true
```

With `enable_schedule = false` (the default), no EventBridge resources are created at all.

---

## Cost

All Day 2 resources are pay-per-use; a lab session is effectively free:

| Resource | Cost |
|----------|------|
| Lambda (9 functions, a few dozen invocations) | < $0.01 (well inside the free tier) |
| Step Functions (a few hundred state transitions) | < $0.01 |
| DynamoDB (on-demand, tiny tables) | < $0.01 |
| SES (a handful of emails) | < $0.01 |
| EventBridge scheduled rule | ~$0 (off by default) |
| **Per run** | **< $0.05** |

The real cost is the Day 1 stack the jobs run on (RDS + Glue) — see the [Day 1 cost table](./day1-ingestion.md#cost). Stop RDS when you are not using it.

---

## Deployment quick-start

Day 2 is applied through the **root** module — it is never applied on its own.

```bash
# 1. Deploy Day 1 first (see the Day 1 quick-start), then add the Day 2 inputs
cat >> infra/terraform.tfvars <<'EOF'
ses_sender_email    = "you@example.com"
ses_receiver_emails = ["you@example.com"]
enable_schedule     = false
EOF

# 2. Apply (creates the Day 2 module resources alongside Day 1)
cd infra && terraform init && terraform apply -auto-approve

# 3. Verify SES identities — open the link in the confirmation email sent to
#    each address. Until you do, Send_Mail silently skips that address.
aws ses get-identity-verification-attributes \
  --identities you@example.com

# 4. Run the staging master job (one execution of all seven jobs in parallel)
SM_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='NT_Accelerate_Datalake_Master_Job'].stateMachineArn" \
  --output text)
aws stepfunctions start-execution --state-machine-arn "$SM_ARN"

# 5. Watch it, then check that an email arrived
aws stepfunctions describe-execution --execution-arn <execution-arn> \
  --query '{status:status, start:startDate, stop:stopDate}'
```

To retry only the jobs that failed, set `RUN_TYPE=RERUN` on the `MASTER_JOB_CONFIG` row (see above) and start the execution again.

```bash
# Teardown — the root destroy removes Day 1 and Day 2 together
cd infra && terraform destroy -auto-approve
```

---

## What this would look like in a real production system

| This lab | Production recommendation |
|----------|--------------------------|
| Lambda code deployed verbatim from lab artifacts | Source in the repo, `python3.9` pinned, unit-tested |
| `RUN_TYPE` flipped by hand in DynamoDB | An operator UI or API that sets run type and validates it |
| SES sandbox with manually verified addresses | Production access, a domain identity, DKIM |
| Step Functions log level `ERROR`, 7-day retention | Retention per compliance policy, alarms on failed executions |
| No dead-letter queue | A DLQ for failed executions plus alerting |
| Static Glue parallelism (7 at once) | Concurrency limits sized to account Glue quotas |
| Master-job status as the only gate | Data-quality gates before marking a layer successful |

The gap between "works in the lab" and "production-ready" is, again, mostly failure modes: what happens when SES throttles, when Glue quotas are hit, when a run half-succeeds. The master-job pattern gives you the hooks — status rows, retries, notifications — to handle those; hardening them is Day 3 territory.

---

## What's next

Day 3 builds the silver and gold layers: the transformations that clean, deduplicate, and conform the bronze Parquet into Delta tables (silver), pre-aggregate business metrics (gold), and load into Redshift for SQL analytics. The `LakeHouse` and `RedshiftDW` master jobs provisioned here are already waiting to orchestrate them, gated on `Check_Staging_Master_Job_Status`. See [Day 3 — Transform & Serve](./day3-lakehouse-transform.md).

---

*This series is based on the AWS TechCamp 2022 Day 1–3 labs, rebuilt as Terraform for reproducibility and used as a teaching example for data lakehouse architecture on AWS.*
