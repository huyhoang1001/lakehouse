# Requirements Document

## Introduction

Day 2 of the NT Accelerate TechCamp lakehouse series adds a full orchestration layer on top of the Day 1 extraction stack. Day 1 extracts seven Tickit tables from RDS SQL Server into S3 bronze as Parquet using AWS Glue; Day 2 wraps those jobs in a master-job control system driven by AWS Step Functions, AWS Lambda, and Amazon DynamoDB. The system supports two run modes — NEW (fresh daily run) and RERUN (selective retry of failed jobs) — and sends an HTML job-status email via Amazon SES after each execution.

All infrastructure is provisioned with Terraform in a new `infra/day2/` module that references but does not modify the existing Day 1 `infra/` module. The nine Lambda functions and three Step Function state machine definitions are deployed verbatim from the provided source artifacts.

## Glossary

- **Step_Functions**: AWS Step Functions, the managed state machine service orchestrating the Day 2 workflow.
- **Lambda**: AWS Lambda functions that implement each control-plane decision in the orchestration workflow.
- **DynamoDB**: Amazon DynamoDB, the NoSQL control-plane store for job configuration, run state, and mail configuration.
- **Glue_Job**: An AWS Glue Spark ETL job that extracts one Tickit table into S3 bronze (defined in Day 1).
- **Master_Job**: The Step Functions state machine that orchestrates all Glue jobs for a given layer (Staging, LakeHouse, RedshiftDW).
- **Staging_Master_Job**: The Day 2 state machine `NT_Accelerate_Datalake_Master_Job` that orchestrates the seven Day 1 extraction Glue jobs.
- **MASTER_JOB_CONFIG**: DynamoDB table `NT_Accelerate_MASTER_JOB_CONFIG` (PK: `ID` N) storing run type, rerun date, batch ID, and last run status per master job.
- **JOB_CONFIG**: DynamoDB table `NT_Accelerate_JOB_CONFIG` (PK: `ID` N), created in Day 1, storing per-Glue-job parameters; extended in Day 2 with `LAYER`, `MULTIPLE_RUN`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `POSTSCRIPT`, `PRESCRIPT`, and `TEMP_FOLDER` columns.
- **JOB_STATUS**: DynamoDB table `NT_Accelarate_JOB_STATUS` (PK: `JOB_NAME` S) — intentional misspelling, must not be corrected.
- **JOB_LOG**: DynamoDB table `NT_Accelerate_JOB_LOG` storing historical run records per job.
- **WATERMARKTABLE**: DynamoDB table `NT_Acccelarate_WATERMARKTABLE` — intentional misspelling, must not be corrected.
- **Mail_Config**: DynamoDB table `NT_Accelerate_Mail_Config` (PK: `ID` N) storing SES sender and receiver email addresses.
- **RUN_TYPE**: The execution mode stored in MASTER_JOB_CONFIG: `NEW` (fresh daily run) or `RERUN` (selective retry).
- **BATCH_ID**: A monotonically increasing integer in MASTER_JOB_CONFIG incremented on each NEW run.
- **MULTIPLE_RUN**: A boolean flag in JOB_CONFIG. When `FALSE`, a Glue job runs at most once per day.
- **SES**: Amazon Simple Email Service, used to send the HTML job-status notification email.
- **Terraform_Module**: A self-contained Terraform configuration; `infra/day2/` is the Day 2 module.
- **archive_file**: Terraform `hashicorp/archive` data source used to ZIP Lambda source files for deployment.

---

## Requirements

### Requirement 1: Terraform Module Structure

**User Story:** As a data platform engineer, I want all Day 2 infrastructure defined in a separate Terraform module `infra/day2/`, so that Day 1 resources are never modified and both stacks can be managed independently.

#### Acceptance Criteria

1. THE Terraform_Module SHALL define all Day 2 resources under the directory path `infra/day2/`.
2. THE Terraform_Module SHALL reference the existing S3 bucket name and Day 1 DynamoDB table ARNs via Terraform remote state or input variables rather than hardcoding resource identifiers.
3. THE Terraform_Module SHALL NOT modify, import, or destroy any resource file under `infra/` (the Day 1 module).
4. THE Terraform_Module SHALL accept `aws_region`, `bucket_name`, `day1_state_path`, and `tags` as input variables with documented descriptions.
5. WHEN `terraform init && terraform apply` is run from `infra/day2/`, THE Terraform_Module SHALL provision all Day 2 resources without manual console intervention.

---

### Requirement 2: Lambda Function Deployment

**User Story:** As a data platform engineer, I want all nine Lambda functions deployed via Terraform using `archive_file` ZIP packaging, so that source code is version-controlled and deployable without manual console steps.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create one `aws_lambda_function` resource for each of the nine Lambda functions: `NT_Accelerate_Read_Run_Type`, `NT_Accelerate_Check_Job_Status`, `NT_Accelerate_Truncate_Job_Status`, `NT_Accelerate_Is_Allow_Running`, `NT_Accelerate_Check_Job_ReRun`, `NT_Accelerate_Update_Job_Status`, `NT_Accelerate_Update_MasterJob_Status`, `NT_Accelerate_Check_Staging_Master_Job_Status`, and `NT_Accelerate_Send_Mail`.
2. THE Terraform_Module SHALL use `data "archive_file"` to ZIP each Lambda source file from `instruction/day2/Day 2 source 2/Day 2 source/Lambda/` and deploy the resulting archive as the Lambda function code.
3. THE Terraform_Module SHALL configure each Lambda function with Python 3.9 or later runtime.
4. THE Terraform_Module SHALL deploy Lambda function packages to the existing S3 bucket under prefix `lambda/` using `aws_s3_object` resources, and configure each `aws_lambda_function` to load code from that S3 object.
5. WHEN a Lambda source file changes, THE Terraform_Module SHALL detect the change via the `archive_file` output hash and trigger a Lambda function update on the next `terraform apply`.

---

### Requirement 3: IAM Role for Lambda Functions

**User Story:** As a data platform engineer, I want a least-privilege IAM role attached to all nine Lambda functions, so that the functions can access only the DynamoDB tables, Glue jobs, SES, and CloudWatch Logs they need.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create an IAM role `NT_Accelerate_LambdaRole` with a trust policy allowing `lambda.amazonaws.com` to assume it.
2. THE Terraform_Module SHALL attach an inline scoped policy granting `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`, and `dynamodb:Scan` on the six DynamoDB table ARNs: `NT_Accelerate_JOB_CONFIG`, `NT_Accelerate_JOB_LOG`, `NT_Accelarate_JOB_STATUS`, `NT_Acccelarate_WATERMARKTABLE`, `NT_Accelerate_MASTER_JOB_CONFIG`, and `NT_Accelerate_Mail_Config`.
3. THE Terraform_Module SHALL grant `glue:StartJobRun` and `glue:GetJobRun` for all Glue job ARNs in the account under `arn:aws:glue:us-east-1:*:job/*`.
4. THE Terraform_Module SHALL grant `ses:SendEmail` and `ses:GetIdentityVerificationAttributes` on `*` within the same region.
5. THE Terraform_Module SHALL grant `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents` on `arn:aws:logs:*:*:*`.
6. THE Terraform_Module SHALL NOT attach `AdministratorAccess` or any AWS managed policy broader than the specific actions listed above.

---

### Requirement 4: IAM Role for Step Functions

**User Story:** As a data platform engineer, I want a least-privilege IAM role for the Step Functions state machines, so that they can invoke Lambda and start Glue jobs without over-broad permissions.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create an IAM role `NT_Accelerate_StepFunctionsRole` with a trust policy allowing `states.amazonaws.com` to assume it.
2. THE Terraform_Module SHALL grant `lambda:InvokeFunction` on the nine Lambda function ARNs created in Requirement 2.
3. THE Terraform_Module SHALL grant `glue:StartJobRun` and `glue:GetJobRun` on `arn:aws:glue:us-east-1:*:job/*`.
4. THE Terraform_Module SHALL grant `logs:CreateLogDelivery`, `logs:GetLogDelivery`, `logs:UpdateLogDelivery`, `logs:DeleteLogDelivery`, `logs:ListLogDeliveries`, `logs:PutLogEvents`, `logs:PutResourcePolicy`, `logs:DescribeResourcePolicies`, and `logs:DescribeLogGroups` for Step Functions CloudWatch Logs delivery.

---

### Requirement 5: DynamoDB Tables for Day 2

**User Story:** As a data platform engineer, I want two new DynamoDB tables provisioned and seeded by Terraform, so that the Master Job and Mail configuration are available before any Step Functions execution.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create a DynamoDB table named exactly `NT_Accelerate_MASTER_JOB_CONFIG` with hash key `ID` (type N) and billing mode `PAY_PER_REQUEST`.
2. THE Terraform_Module SHALL seed `NT_Accelerate_MASTER_JOB_CONFIG` with one item: `ID=1, RUN_TYPE=NEW, RERUN_DATE=2024-01-01, BATCH_ID=0, LAST_RUN_DATE=2024-01-01, LAST_RUN_STATUS=NEW`.
3. THE Terraform_Module SHALL create a DynamoDB table named exactly `NT_Accelerate_Mail_Config` with hash key `ID` (type N) and billing mode `PAY_PER_REQUEST`.
4. THE Terraform_Module SHALL seed `NT_Accelerate_Mail_Config` with one placeholder item: `ID=1, SENDER=sender@example.com, RECEIVER=["recipient@example.com"]`.
5. THE Terraform_Module SHALL NOT rename or modify the DynamoDB tables `NT_Accelarate_JOB_STATUS`, `NT_Accelerate_JOB_CONFIG`, `NT_Accelerate_JOB_LOG`, or `NT_Acccelarate_WATERMARKTABLE` created in Day 1.

---

### Requirement 6: JOB_CONFIG Table Extension for Day 2

**User Story:** As a data platform engineer, I want the Day 1 `NT_Accelerate_JOB_CONFIG` seed items updated to include the additional columns that `NT_Accelerate_Is_Allow_Running` reads, so that the Lambda function can retrieve all required parameters without raising a `KeyError`.

#### Acceptance Criteria

1. THE Terraform_Module SHALL update each of the seven `NT_Accelerate_JOB_CONFIG` seed items to include the columns `LAYER`, `MULTIPLE_RUN`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `POSTSCRIPT`, `PRESCRIPT`, and `TEMP_FOLDER`.
2. WHEN the `LAYER` value for a Tickit extraction job is `STAGING`, THE Terraform_Module SHALL set `MULTIPLE_RUN=FALSE`, `CATALOG_CON=conRDS_tickit`, `LAKEHOUSE_LOCATION=` (empty string), `POSTSCRIPT=` (empty string), `PRESCRIPT=` (empty string), and `TEMP_FOLDER=` (empty string).
3. THE Terraform_Module SHALL preserve all existing column values (`ID`, `JOB_NAME`, `p_src_tableName`, `p_tar_tablename`, `p_is_incremental_load`, `p_region`, `p_src_databaseName`, `p_tar_databaseName`, `p_catalog_conn`) from the Day 1 seed data unchanged.
4. WHEN the Day 2 Terraform module is applied, THE Terraform_Module SHALL apply the JOB_CONFIG updates using `aws_dynamodb_table_item` resources with `lifecycle { ignore_changes = [] }` so subsequent runtime updates to the table are not overwritten.

---

### Requirement 7: Step Functions State Machine Deployment

**User Story:** As a data platform engineer, I want the three Step Functions state machines deployed from the provided JSON definitions with Terraform-managed ARN substitution, so that hardcoded account IDs from the original lab are replaced with the deploying account's ID at apply time.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create three `aws_sfn_state_machine` resources named `NT_Accelerate_Datalake_Master_Job`, `NT_Accelerate_LakeHouse_Master_Job`, and `NT_Accelerate_RedshiftDW_Master_Job`.
2. THE Terraform_Module SHALL load the state machine definition from the corresponding JSON file in `instruction/day2/Day 2 source 2/Day 2 source/Step function/` using the Terraform `templatefile` or `replace` function.
3. THE Terraform_Module SHALL replace all occurrences of the hardcoded account ID `377414509754` in the JSON definitions with `data.aws_caller_identity.current.account_id`.
4. THE Terraform_Module SHALL replace all Lambda ARN stems in the JSON definitions with the ARNs of the Lambda functions created in Requirement 2.
5. WHEN the Step Functions state machine type is set to `STANDARD`, THE Terraform_Module SHALL enable CloudWatch Logs delivery at the `ERROR` level to a log group named `/aws/states/NT_Accelerate_Datalake_Master_Job`.
6. THE Terraform_Module SHALL attach the IAM role created in Requirement 4 to all three state machines.

---

### Requirement 8: Run Type Control (NEW vs RERUN)

**User Story:** As a data engineer, I want the Staging Master Job to support both NEW and RERUN execution modes driven by `NT_Accelerate_MASTER_JOB_CONFIG`, so that I can either start a fresh daily run or selectively retry only the jobs that failed in the previous run.

#### Acceptance Criteria

1. WHEN the Staging_Master_Job starts with `RUN_TYPE=NEW`, THE Step_Functions SHALL read `MASTER_JOB_CONFIG` row `ID=1`, set `run_date` to today's date in `YYYY-MM-DD` format, and increment `BATCH_ID` by 1.
2. WHEN `RUN_TYPE=NEW` and `NT_Accelarate_JOB_STATUS` contains any item with `PROCESS_STATUS=FAILED`, THE Step_Functions SHALL update `MASTER_JOB_CONFIG` with `LAST_RUN_STATUS=FAILED` and transition to the `Fail` terminal state without running any Glue jobs.
3. WHEN `RUN_TYPE=NEW` and `NT_Accelarate_JOB_STATUS` contains no FAILED items, THE Step_Functions SHALL delete all items from `NT_Accelarate_JOB_STATUS` before launching the parallel Glue job branches.
4. WHEN the Staging_Master_Job starts with `RUN_TYPE=RERUN`, THE Step_Functions SHALL skip the JOB_STATUS check and proceed directly to the parallel Glue job branches using the `RERUN_DATE` value from `MASTER_JOB_CONFIG` as `run_date`.
5. IF `MASTER_JOB_CONFIG` row `ID=1` does not exist, THEN THE Step_Functions SHALL transition to the `Stop because of not configure yet` Fail state immediately.

---

### Requirement 9: Per-Job Run Decision Logic

**User Story:** As a data engineer, I want each parallel Glue job branch to decide independently whether to run, skip, or be treated as already succeeded, so that the orchestration supports both single-run and multiple-run job configurations correctly.

#### Acceptance Criteria

1. WHEN `NT_Accelerate_Is_Allow_Running` is invoked for a Glue job with `MULTIPLE_RUN=FALSE` and `RUN_TYPE=NEW`, THE Lambda SHALL check `NT_Accelerate_JOB_LOG` for a record matching `JOB_NAME` and `run_date`; if a record exists, the Lambda SHALL return `is_ran=Yes`.
2. WHEN `NT_Accelerate_Is_Allow_Running` returns `is_ran=Yes`, THE Step_Functions SHALL invoke `NT_Accelerate_Update_Job_Status` to record `PROCESS_STATUS=SUCCEEDED` in `NT_Accelarate_JOB_STATUS` and skip the Glue job run.
3. WHEN `NT_Accelerate_Is_Allow_Running` returns `is_ran=No`, THE Step_Functions SHALL start the Glue job using `states:::glue:startJobRun.sync` and pass all job parameters from the Lambda response as Glue job arguments.
4. WHEN `RUN_TYPE=RERUN` and a job entry exists in `NT_Accelarate_JOB_STATUS` with `PROCESS_STATUS=FAILED`, THE Lambda `NT_Accelerate_Is_Allow_Running` SHALL delete that entry and return `is_ran=No` so the job reruns.
5. WHEN `RUN_TYPE=RERUN` and a job entry exists in `NT_Accelarate_JOB_STATUS` with `PROCESS_STATUS=SUCCEEDED`, THE Lambda `NT_Accelerate_Is_Allow_Running` SHALL return `is_ran=Yes` so the job is skipped.
6. WHEN `RUN_TYPE=RERUN` and a job has no entry in `NT_Accelarate_JOB_STATUS`, THE Lambda `NT_Accelerate_Is_Allow_Running` SHALL return `is_ran=No` so the job runs.

---

### Requirement 10: Post-Run Status Update and Email Notification

**User Story:** As a data engineer, I want the master job to update its own status and send an HTML email summary after all parallel Glue branches complete, so that operators know immediately which jobs succeeded or failed.

#### Acceptance Criteria

1. WHEN all seven parallel Glue job branches complete (regardless of individual job outcome), THE Step_Functions SHALL invoke `NT_Accelerate_Update_MasterJob_Status` with `p_status=SUCCEEDED` to update `MASTER_JOB_CONFIG` row `ID=1`.
2. WHEN `NT_Accelerate_Send_Mail` is invoked, THE Lambda SHALL read sender and receiver addresses from `NT_Accelerate_Mail_Config` row `ID=1`.
3. WHEN `NT_Accelerate_Send_Mail` is invoked, THE Lambda SHALL query `NT_Accelarate_JOB_STATUS` for all items with `PROCESS_STATUS=FAILED` or `PROCESS_STATUS=SUCCEEDED` and compose an HTML table containing `JOB_NAME`, `PROCESS_STATUS`, `RUN_DATE`, and `ERROR_MSG` for each row.
4. WHEN the HTML table contains at least one row, THE Lambda SHALL send the email via SES to only the receiver addresses that have `VerificationStatus=Success`.
5. WHEN no receiver address has `VerificationStatus=Success`, THE Lambda SHALL return without raising an exception.

---

### Requirement 11: SES Email Identity Configuration

**User Story:** As a data platform engineer, I want SES identity verification managed or documented by Terraform, so that the Send_Mail Lambda can send emails without manual console setup.

#### Acceptance Criteria

1. THE Terraform_Module SHALL create `aws_ses_email_identity` resources for the placeholder sender and receiver addresses defined in the `NT_Accelerate_Mail_Config` seed item.
2. WHEN SES is in sandbox mode, THE Terraform_Module documentation (README or Terraform output) SHALL state that both sender and receiver addresses must be verified in SES before the Send_Mail Lambda will deliver email.
3. WHEN real email addresses are known, THE Terraform_Module SHALL accept `ses_sender_email` and `ses_receiver_emails` as input variables that override the placeholder seed values in both the DynamoDB table item and the `aws_ses_email_identity` resources.

---

### Requirement 12: EventBridge Scheduled Trigger (Optional)

**User Story:** As a data engineer, I want an optional EventBridge schedule that triggers the Staging Master Job daily, so that the pipeline runs automatically without manual Step Functions execution.

#### Acceptance Criteria

1. WHERE the input variable `enable_schedule` is `true`, THE Terraform_Module SHALL create an `aws_cloudwatch_event_rule` with a daily cron schedule targeting the `NT_Accelerate_Datalake_Master_Job` state machine.
2. WHERE `enable_schedule` is `true`, THE Terraform_Module SHALL create an `aws_cloudwatch_event_target` and an IAM role allowing EventBridge to start the state machine execution.
3. WHERE `enable_schedule` is `false` (default), THE Terraform_Module SHALL not create any EventBridge resources.

---

### Requirement 13: Table Name Preservation (Intentional Typos)

**User Story:** As a data platform engineer, I want the DynamoDB table names with intentional misspellings preserved exactly as defined in the Lambda source code, so that all Lambda functions resolve the correct tables at runtime without any code changes.

#### Acceptance Criteria

1. THE Terraform_Module SHALL define the DynamoDB table name `NT_Accelarate_JOB_STATUS` (missing `e` in "Accelerate") in locals and use that local for every resource and policy that references this table.
2. THE Terraform_Module SHALL define the DynamoDB table name `NT_Acccelarate_WATERMARKTABLE` (triple `c`, missing `e` in "Accelerate") in locals and use that local for every resource and policy that references this table.
3. THE Terraform_Module SHALL add a comment on each misspelled local value stating that the spelling is intentional and must not be corrected.

---

### Requirement 14: Cross-Layer Gate — Check Staging Master Job Status

**User Story:** As a data engineer, I want the `NT_Accelerate_Check_Staging_Master_Job_Status` Lambda to be deployable as a gate for downstream Day 3 jobs, so that the LakeHouse and RedshiftDW master jobs can verify the staging layer ran successfully before proceeding.

#### Acceptance Criteria

1. THE Lambda `NT_Accelerate_Check_Staging_Master_Job_Status` SHALL accept `p_run_date` in `YYYY-MM-DD` format as its event input.
2. WHEN `NT_Accelerate_MASTER_JOB_CONFIG` contains a row with `ID=1`, `LAST_RUN_DATE` equal to `p_run_date`, and `LAST_RUN_STATUS=SUCCEEDED`, THE Lambda SHALL return `{"flag": true}`.
3. WHEN no such row exists, THE Lambda SHALL return `{"flag": false}`.
