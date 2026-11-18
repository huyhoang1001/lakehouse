# Design Document: NT Accelerate Day 2 Orchestration

## Overview

Day 2 wraps the seven Day 1 Glue extraction jobs in a master-job control system. The core pattern is a Step Functions state machine that decides — per execution — whether each job should run from scratch, be skipped (already ran today), or be retried (failed in a previous run). Nine Lambda functions handle every DynamoDB read/write decision. All infrastructure is Terraform-managed in a new `infra/day2/` module that reads Day 1 state as remote state and never modifies Day 1 files.

The design deliberately keeps Lambda function source code **verbatim** from the provided artifacts. Terraform only packages, deploys, and wires them; it does not alter Python logic.

---

## Architecture

```
                          ┌──────────────────────────────────────────────────────────┐
                          │  infra/day2/ (Terraform module)                           │
                          │                                                            │
  EventBridge             │  ┌──────────────────────────────────────────────────────┐ │
  (optional daily cron)──►│  │  Step Functions: NT_Accelerate_Datalake_Master_Job   │ │
                          │  │                                                        │ │
                          │  │  1. Read_Run_Type ──► Config check ──► NEW/RERUN?     │ │
                          │  │  2a. NEW: Check_Job_Status                            │ │
                          │  │       FAILED exists? → Update_MasterJob(FAILED)→Fail │ │
                          │  │       No FAILED?     → Truncate_Job_Status            │ │
                          │  │  2b. RERUN: proceed directly                          │ │
                          │  │  3. Parallel (7 branches):                            │ │
                          │  │     Is_Allow_Running → is_ran?                        │ │
                          │  │       Yes → Update_Job_Status(SUCCEEDED)             │ │
                          │  │       No  → Glue startJobRun.sync                    │ │
                          │  │  4. Update_MasterJob_Status(SUCCEEDED)               │ │
                          │  │  5. Send_Mail                                         │ │
                          │  └────────────────────────┬───────────────────────────── ┘ │
                          │                           │                                 │
                          │  ┌────────────────────────▼───────────────────────────── ┐ │
                          │  │  Lambda functions (9)                                  │ │
                          │  │  NT_Accelerate_Read_Run_Type                          │ │
                          │  │  NT_Accelerate_Check_Job_Status                       │ │
                          │  │  NT_Accelerate_Truncate_Job_Status                    │ │
                          │  │  NT_Accelerate_Is_Allow_Running                       │ │
                          │  │  NT_Accelerate_Check_Job_ReRun                        │ │
                          │  │  NT_Accelerate_Update_Job_Status                      │ │
                          │  │  NT_Accelerate_Update_MasterJob_Status                │ │
                          │  │  NT_Accelerate_Check_Staging_Master_Job_Status        │ │
                          │  │  NT_Accelerate_Send_Mail                              │ │
                          │  └────────────────────────┬───────────────────────────── ┘ │
                          │                           │                                 │
                          │  ┌────────────────────────▼───────────────────────────── ┐ │
                          │  │  DynamoDB (6 tables)                                   │ │
                          │  │  NT_Accelerate_MASTER_JOB_CONFIG  ← new Day 2         │ │
                          │  │  NT_Accelerate_Mail_Config         ← new Day 2         │ │
                          │  │  NT_Accelerate_JOB_CONFIG          ← extended Day 1    │ │
                          │  │  NT_Accelerate_JOB_LOG             ← read-only Day 1   │ │
                          │  │  NT_Accelarate_JOB_STATUS          ← read/write Day 1  │ │
                          │  │  NT_Acccelarate_WATERMARKTABLE     ← read-only Day 1   │ │
                          │  └────────────────────────────────────────────────────── ┘ │
                          │                                                            │
                          │  IAM: NT_Accelerate_LambdaRole                            │
                          │  IAM: NT_Accelerate_StepFunctionsRole                     │
                          │  SES: email identity verification                          │
                          └──────────────────────────────────────────────────────────┘
                                       │ read-only references
                          ┌────────────▼──────────────────────────────────────────────┐
                          │  infra/ (Day 1 — unchanged)                               │
                          │  S3 bucket · Glue jobs · RDS · Networking · Day 1 tables │
                          └───────────────────────────────────────────────────────────┘
```

### Staging Master Job State Machine Flow

```
StartAt: Read run_type from MASTER JOB CONFIG
    │
    ▼
Choice: flag == true?
    ├── false → Fail: "Stop because of not configure yet"
    └── true  →
            Choice: run_type == NEW or RERUN?
            ├── RERUN → Run jobs in parallel
            └── NEW   →
                    Lambda: Check_Job_Status
                        │
                        ▼
                    Choice: FailedJobExisting?
                    ├── true  → Lambda: Update_MasterJob_Status(FAILED) → Fail
                    └── false → Lambda: Truncate_Job_Status
                                    │
                                    ▼
                            Run jobs in parallel (7 branches)
                                    │
                                    ▼ (all branches complete)
                            Lambda: Update_MasterJob_Status(SUCCEEDED)
                                    │
                                    ▼
                            Lambda: Send_Mail
                                    │
                                    ▼
                            End

Each parallel branch (identical structure per job):
    Lambda: Is_Allow_Running(p_job_name, p_run_date, p_run_type)
        │
        ▼
    Choice: is_ran == Yes?
    ├── Yes → Lambda: Update_Job_Status(SUCCEEDED) → End
    └── No  → Glue startJobRun.sync(job_name, args from Is_Allow_Running) → End
```

---

## Components and Interfaces

### 2.1 Terraform Module: `infra/day2/`

| File | Purpose |
|------|---------|
| `versions.tf` | Required providers (aws ≥ 5.x, archive ≥ 2.x) and backend config |
| `variables.tf` | Input variables: `aws_region`, `bucket_name`, `day1_state_path`, `ses_sender_email`, `ses_receiver_emails`, `enable_schedule`, `tags` |
| `locals.tf` | Table names (with intentional typo comments), ARN stems, Lambda source paths |
| `data.tf` | `data.aws_caller_identity`, `data.aws_region`, remote state for Day 1 outputs |
| `iam.tf` | `NT_Accelerate_LambdaRole` and `NT_Accelerate_StepFunctionsRole` |
| `lambda.tf` | 9× `data.archive_file` + `aws_s3_object` + `aws_lambda_function` |
| `dynamodb.tf` | 2 new tables + seed items; JOB_CONFIG update items |
| `sfn.tf` | 3× `aws_sfn_state_machine` with ARN substitution + CloudWatch log group |
| `ses.tf` | `aws_ses_email_identity` for sender and receivers |
| `eventbridge.tf` | Conditional schedule + target + IAM role (gated by `enable_schedule`) |
| `outputs.tf` | Lambda ARNs, state machine ARNs, DynamoDB table names |

### 2.2 Lambda Function Interfaces

Each Lambda is a pure Python 3.9 function with the following event/response contracts:

| Function | Event Input | Return Value |
|----------|-------------|--------------|
| `Read_Run_Type` | `{p_masterjob_id: N}` | `{flag, run_type, run_date, batch_id}` |
| `Check_Job_Status` | (any) | `{FailedJobExisting: bool}` |
| `Truncate_Job_Status` | (any) | `true` |
| `Is_Allow_Running` | `{p_job_name, p_run_date, p_run_type}` | `{is_ran, var_job_name, var_run_date, var_catalog_con, var_incremental_load, var_multiple_run, var_region, var_src_db, var_scr_table, var_trg_db, var_trg_table, var_lakehouse_location, var_postscript, var_prescript, var_tempfolder}` |
| `Check_Job_ReRun` | `{JobName}` | `{flag: bool}` |
| `Update_Job_Status` | `{JobName, BatchId, RunDate}` | `true` |
| `Update_MasterJob_Status` | `{p_masterjob_id, p_run_date, p_status}` | `true` |
| `Check_Staging_Master_Job_Status` | `{p_run_date}` | `{flag: bool}` |
| `Send_Mail` | (any) | `true` |

### 2.3 Step Functions State Machines

| State Machine | Input | Parallel Branches | Post-Parallel Steps |
|---------------|-------|-------------------|---------------------|
| `NT_Accelerate_Datalake_Master_Job` | (none; reads DDB) | 7 (one per Day 1 Glue job) | Update_MasterJob_Status, Send_Mail |
| `NT_Accelerate_LakeHouse_Master_Job` | (none) | Varies (Day 3 scope) | Update_MasterJob_Status, Send_Mail |
| `NT_Accelerate_RedshiftDW_Master_Job` | (none) | Varies (Day 3 scope) | Update_MasterJob_Status, Send_Mail |

---

## Data Models

### MASTER_JOB_CONFIG (new Day 2 table)

| Attribute | Type | Notes |
|-----------|------|-------|
| `ID` | N (PK) | 1 = Staging Master, 2 = LakeHouse Master, 3 = Redshift Master |
| `RUN_TYPE` | S | `NEW` or `RERUN` |
| `RERUN_DATE` | S | `YYYY-MM-DD`; used as `run_date` for RERUN mode |
| `BATCH_ID` | N | Incremented on each NEW run |
| `LAST_RUN_DATE` | S | `YYYY-MM-DD`; set by Update_MasterJob_Status |
| `LAST_RUN_STATUS` | S | `SUCCEEDED` or `FAILED`; set by Update_MasterJob_Status |

Seed row: `{ID:1, RUN_TYPE:NEW, RERUN_DATE:2024-01-01, BATCH_ID:0, LAST_RUN_DATE:2024-01-01, LAST_RUN_STATUS:NEW}`

### Mail_Config (new Day 2 table)

| Attribute | Type | Notes |
|-----------|------|-------|
| `ID` | N (PK) | 1 = default mail profile |
| `SENDER` | S | SES-verified sender address |
| `RECEIVER` | SS (string set) | One or more SES-verified receiver addresses |

Seed row: `{ID:1, SENDER:sender@example.com, RECEIVER:["recipient@example.com"]}` — operator replaces with verified addresses.

### JOB_CONFIG extensions (Day 2 adds columns to Day 1 items)

The existing seven seed items in `NT_Accelerate_JOB_CONFIG` require the following additional attributes for `Is_Allow_Running` to function without a `KeyError`:

| New Attribute | Type | Staging value |
|---------------|------|---------------|
| `LAYER` | S | `STAGING` |
| `MULTIPLE_RUN` | S | `FALSE` |
| `CATALOG_CON` | S | `conRDS_tickit` |
| `LAKEHOUSE_LOCATION` | S | `""` (empty) |
| `POSTSCRIPT` | S | `""` (empty) |
| `PRESCRIPT` | S | `""` (empty) |
| `TEMP_FOLDER` | S | `""` (empty) |

Because the Day 1 `aws_dynamodb_table_item` resources are in a different Terraform state, the Day 2 module manages these extended items as **separate** `aws_dynamodb_table_item` resources targeting the Day 1 table but keyed by the same PK values. The Day 2 items include all old and new attributes to form a complete, consistent item. Terraform will overwrite the existing item on `apply` and from that point manage the full item.

### JOB_STATUS (Day 1 table, read/written by Day 2)

| Attribute | Type | Notes |
|-----------|------|-------|
| `JOB_NAME` | S (PK) | Glue job name |
| `BATCH_ID` | N | Batch ID of the run that wrote this item |
| `RUN_DATE` | S | `YYYY-MM-DD` |
| `PROCESS_STATUS` | S | `SUCCEEDED` or `FAILED` |
| `ERROR_MSG` | S | Error detail or `"Job ran in day"` for skipped jobs |

---

## Error Handling

### State Machine Failures

- All Lambda `Task` states in the Step Functions definition include `Retry` with `MaxAttempts: 6`, `IntervalSeconds: 2`, `BackoffRate: 2` for `Lambda.ServiceException`, `Lambda.AWSLambdaException`, and `Lambda.SdkClientException`. This matches the original JSON definitions exactly.
- The `Fail` terminal state in the Staging Master Job is reached when: (a) `MASTER_JOB_CONFIG` row `ID=1` does not exist, or (b) `RUN_TYPE=NEW` and unresolved FAILED jobs remain in `JOB_STATUS`.
- Glue job failures within parallel branches propagate as state machine errors and are captured in the Step Functions execution history. The Step Functions execution itself fails if any parallel branch fails.

### Lambda Error Handling

- Lambda functions do not implement structured exception handling beyond `try/except` with `print(e)` in `Truncate_Job_Status`. This matches the source verbatim — no changes are made to Lambda code.
- If `Send_Mail` fails (e.g. SES throttle), it returns `True` without rethrowing, so the state machine still completes `SUCCEEDED`.

### SES Sandbox Constraint

- `Send_Mail` calls `ses.get_identity_verification_attributes` before sending and filters out unverified addresses. If no receiver is verified, it skips the `send_email` call entirely rather than raising an error.
- The operator must verify the sender address in SES before the Lambda can send any email. This is documented in the module README and enforced by the `aws_ses_email_identity` resource.

### Terraform Apply Ordering

- The Day 2 `aws_dynamodb_table_item` resources for JOB_CONFIG extensions depend on the Day 1 table existing, referenced via `data.terraform_remote_state` or by passing the table name as a variable. Terraform `depends_on` ensures items are written only after tables exist.
- Lambda ZIPs are uploaded to S3 before Lambda functions are created or updated via `source_code_hash`.

---

## Testing Strategy

This feature is Infrastructure as Code (Terraform) deploying fixed Lambda code artifacts. Property-based testing is not appropriate for the following reasons:

- All Terraform resources are declarative configuration, not pure functions with variable logic.
- The Lambda functions are deployed verbatim from source — their logic is validated by the original lab, not by this spec.
- The Step Functions definitions are deployed from JSON files; correctness of the state machine logic is structural (ARN substitution), not algorithmic.

The testing strategy uses example-based and integration tests only.

### Unit / Example Tests (Terraform)

**Terraform plan validation** (`terraform validate` and `terraform plan`):
- Verify all nine Lambda `aws_lambda_function` resources appear in the plan with the correct runtime.
- Verify two new DynamoDB tables appear in the plan with the correct names and billing mode.
- Verify three `aws_sfn_state_machine` resources appear with the correct names.
- Verify no hardcoded account ID `377414509754` appears in any `aws_sfn_state_machine` definition after template substitution.
- Verify that `enable_schedule = false` produces zero `aws_cloudwatch_event_rule` resources.
- Verify that `enable_schedule = true` produces exactly one `aws_cloudwatch_event_rule` resource.

### Integration Tests (post-apply smoke tests)

Performed manually or via a CI step after `terraform apply`:

1. **Lambda invocability**: Invoke `NT_Accelerate_Read_Run_Type` with `{"p_masterjob_id": 1}` and assert the response contains keys `flag`, `run_type`, `run_date`, and `batch_id` with `flag=true` and `run_type=NEW`.
2. **JOB_CONFIG columns**: Scan `NT_Accelerate_JOB_CONFIG` and assert all seven items contain the `LAYER`, `MULTIPLE_RUN`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `POSTSCRIPT`, `PRESCRIPT`, and `TEMP_FOLDER` attributes.
3. **MASTER_JOB_CONFIG seed**: Query `NT_Accelerate_MASTER_JOB_CONFIG` with `ID=1` and assert `RUN_TYPE=NEW` and `BATCH_ID=0`.
4. **State machine execution (NEW run, dry-run via mock)**: Start `NT_Accelerate_Datalake_Master_Job` and verify the execution reaches the `Run jobs in parallel` state without entering the `Fail` state (requires at least one Glue job to exist from Day 1).
5. **ARN substitution check**: Describe `NT_Accelerate_Datalake_Master_Job` and assert the definition JSON contains the actual deploying account ID, not `377414509754`.
6. **SES identity**: Call `ses:GetIdentityVerificationAttributes` on the seed sender address and assert the resource was created (verification status will be `Pending` until the email link is clicked).
