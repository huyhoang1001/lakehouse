# Implementation Plan: NT Accelerate Day 2 Orchestration

## Overview

This implementation plan builds the Day 2 orchestration layer on top of the Day 1 extraction stack. All work happens in a new Terraform module `infra/day2/` that references Day 1 state as read-only. Tasks are structured as: setup Terraform module scaffolding, define IAM roles, deploy Lambda functions, deploy Step Functions state machines, provision DynamoDB tables, and wire SES + EventBridge.

All code written here is Terraform HCL — no Python code is modified. Lambda source files are deployed verbatim from `instruction/day2/Day 2 source 2/Day 2 source/Lambda/`.

---

## Tasks

- [x] 1. Set up Terraform module scaffolding for `infra/day2/`
  - Create directory `infra/day2/`
  - Write `versions.tf` with required providers (aws ≥ 5.x, archive ≥ 2.x) and remote backend configuration matching Day 1 pattern
  - Write `variables.tf` with input variables: `aws_region`, `bucket_name`, `day1_state_path`, `ses_sender_email`, `ses_receiver_emails`, `enable_schedule`, `tags`
  - Write `locals.tf` defining table names (with comments marking intentional typos), Lambda source paths, and Lambda function names
  - Write `data.tf` with `data.aws_caller_identity`, `data.aws_region`, and `data.terraform_remote_state` for Day 1 outputs
  - _Requirements: 1.1, 1.2, 1.3, 1.4_

- [x] 2. Define IAM roles and policies
  - [x] 2.1 Create `iam.tf` with `NT_Accelerate_LambdaRole`
    - Write trust policy for `lambda.amazonaws.com`
    - Attach inline scoped policy granting DynamoDB CRUD on six tables (MASTER_JOB_CONFIG, Mail_Config, JOB_CONFIG, JOB_LOG, JOB_STATUS, WATERMARKTABLE)
    - Grant `glue:StartJobRun` and `glue:GetJobRun` on `arn:aws:glue:us-east-1:*:job/*`
    - Grant `ses:SendEmail` and `ses:GetIdentityVerificationAttributes` on `*`
    - Grant CloudWatch Logs permissions
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_
  
  - [x] 2.2 Add `NT_Accelerate_StepFunctionsRole` to `iam.tf`
    - Write trust policy for `states.amazonaws.com`
    - Grant `lambda:InvokeFunction` on the nine Lambda function ARNs
    - Grant `glue:StartJobRun` and `glue:GetJobRun` on `arn:aws:glue:us-east-1:*:job/*`
    - Grant CloudWatch Logs permissions for Step Functions log delivery
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

- [ ] 3. Deploy Lambda functions
  - [ ] 3.1 Create `lambda.tf` with `data "archive_file"` resources for nine Lambda functions
    - Define one `data "archive_file"` per Lambda, sourcing from `instruction/day2/Day 2 source 2/Day 2 source/Lambda/<function>.py`
    - Output type: `zip`
    - _Requirements: 2.2_
  
  - [ ] 3.2 Add S3 upload resources for Lambda ZIPs
    - Write nine `aws_s3_object` resources uploading each ZIP to `s3://<bucket>/lambda/<function>.zip`
    - Use `source = data.archive_file.<name>.output_path`
    - Use `etag = filemd5(data.archive_file.<name>.output_path)` to trigger updates on source change
    - _Requirements: 2.4_
  
  - [ ] 3.3 Add `aws_lambda_function` resources
    - Create nine `aws_lambda_function` resources
    - Runtime: `python3.9`
    - Role: `aws_iam_role.lambda.arn`
    - S3 code reference: `s3_bucket = <bucket>, s3_key = aws_s3_object.<name>.key`
    - Environment variables: `{ REGION = var.aws_region }`
    - Timeout: `60` seconds
    - _Requirements: 2.1, 2.3, 2.5_

- [ ] 4. Provision DynamoDB tables for Day 2
  - [ ] 4.1 Create `dynamodb.tf` with `NT_Accelerate_MASTER_JOB_CONFIG`
    - Hash key: `ID` (N)
    - Billing mode: `PAY_PER_REQUEST`
    - _Requirements: 5.1_
  
  - [ ] 4.2 Seed MASTER_JOB_CONFIG with `aws_dynamodb_table_item`
    - Item: `{ID:1, RUN_TYPE:NEW, RERUN_DATE:2024-01-01, BATCH_ID:0, LAST_RUN_DATE:2024-01-01, LAST_RUN_STATUS:NEW}`
    - Use `jsonencode` to construct DynamoDB item JSON
    - _Requirements: 5.2_
  
  - [ ] 4.3 Add `NT_Accelerate_Mail_Config` table to `dynamodb.tf`
    - Hash key: `ID` (N)
    - Billing mode: `PAY_PER_REQUEST`
    - _Requirements: 5.3_
  
  - [ ] 4.4 Seed Mail_Config with placeholder `aws_dynamodb_table_item`
    - Item: `{ID:1, SENDER:var.ses_sender_email, RECEIVER:[var.ses_receiver_emails]}`
    - Use `jsonencode` with DynamoDB List (L) syntax for RECEIVER
    - _Requirements: 5.4_
  
  - [ ] 4.5 Add JOB_CONFIG extension items to `dynamodb.tf`
    - Create seven `aws_dynamodb_table_item` resources targeting the Day 1 `NT_Accelerate_JOB_CONFIG` table
    - Each item includes all Day 1 columns (`ID`, `JOB_NAME`, `p_src_tableName`, `p_tar_tablename`, `p_is_incremental_load`, `p_region`, `p_src_databaseName`, `p_tar_databaseName`, `p_catalog_conn`) plus new columns (`LAYER`, `MULTIPLE_RUN`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `POSTSCRIPT`, `PRESCRIPT`, `TEMP_FOLDER`)
    - Set `LAYER=STAGING`, `MULTIPLE_RUN=FALSE`, `CATALOG_CON=conRDS_tickit`, empty strings for the others
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

- [ ] 5. Deploy Step Functions state machines
  - [ ] 5.1 Create `sfn.tf` and load Step Functions JSON definitions with ARN substitution
    - Use `templatefile` or `replace` to substitute hardcoded account ID `377414509754` with `data.aws_caller_identity.current.account_id`
    - Replace Lambda ARN stems with `aws_lambda_function.<name>.arn`
    - Store the processed definition in a local variable per state machine
    - _Requirements: 7.2, 7.3, 7.4_
  
  - [ ] 5.2 Add three `aws_sfn_state_machine` resources
    - Names: `NT_Accelerate_Datalake_Master_Job`, `NT_Accelerate_LakeHouse_Master_Job`, `NT_Accelerate_RedshiftDW_Master_Job`
    - Definition: the processed JSON from task 5.1
    - Role ARN: `aws_iam_role.sfn.arn`
    - Type: `STANDARD`
    - _Requirements: 7.1, 7.6_
  
  - [ ] 5.3 Add CloudWatch log group for Step Functions
    - Resource: `aws_cloudwatch_log_group` with name `/aws/states/NT_Accelerate_Datalake_Master_Job`
    - Retention: `7` days (configurable via variable)
    - Configure `logging_configuration` block in each `aws_sfn_state_machine` with `log_destination = aws_cloudwatch_log_group.<name>.arn`, `level = ERROR`
    - _Requirements: 7.5_

- [ ] 6. Configure SES email identities
  - [ ] 6.1 Create `ses.tf` with sender identity
    - Resource: `aws_ses_email_identity` for `var.ses_sender_email`
    - _Requirements: 11.1_
  
  - [ ] 6.2 Add receiver identities
    - Use `for_each = toset(var.ses_receiver_emails)` to create one `aws_ses_email_identity` per receiver address
    - _Requirements: 11.1_
  
  - [ ] 6.3 Write module README documenting SES sandbox verification requirement
    - Create `infra/day2/README.md` with section "SES Configuration" explaining that both sender and receiver must click verification emails in sandbox mode
    - _Requirements: 11.2, 11.3_

- [ ] 7. Add optional EventBridge schedule
  - [ ] 7.1 Create `eventbridge.tf` with conditional schedule rule
    - Use `count = var.enable_schedule ? 1 : 0` on `aws_cloudwatch_event_rule` with daily cron expression `cron(0 8 * * ? *)` (8 AM UTC daily, adjust as needed)
    - _Requirements: 12.1_
  
  - [ ] 7.2 Add event target and IAM role
    - Resource: `aws_cloudwatch_event_target` pointing to `aws_sfn_state_machine.staging.arn`
    - IAM role: trust `events.amazonaws.com`, grant `states:StartExecution` on the Staging Master Job ARN
    - _Requirements: 12.2_

- [ ] 8. Write module outputs
  - Create `infra/day2/outputs.tf` exposing:
    - Lambda function ARNs (map keyed by function name)
    - Step Functions state machine ARNs (map keyed by machine name)
    - DynamoDB table names (MASTER_JOB_CONFIG, Mail_Config)
    - SES identity ARNs (sender, receivers)
    - EventBridge rule ARN (if enabled)
  - _Requirements: 1.5_

- [ ] 9. Checkpoint — Validate Terraform and test apply
  - Run `terraform init` in `infra/day2/`
  - Run `terraform validate` and assert zero errors
  - Run `terraform plan` and assert all expected resources appear
  - Run `terraform apply -auto-approve` in a test account or workspace
  - Invoke `NT_Accelerate_Read_Run_Type` via `aws lambda invoke` with `{"p_masterjob_id": 1}` and assert response contains `flag=true`, `run_type=NEW`
  - Query `NT_Accelerate_MASTER_JOB_CONFIG` and assert row `ID=1` exists with `RUN_TYPE=NEW`
  - Query `NT_Accelerate_JOB_CONFIG` and assert all seven items contain `LAYER`, `MULTIPLE_RUN`, `CATALOG_CON`, `LAKEHOUSE_LOCATION`, `POSTSCRIPT`, `PRESCRIPT`, `TEMP_FOLDER` attributes
  - Describe Step Functions state machine `NT_Accelerate_Datalake_Master_Job` and assert the definition JSON contains the deploying account ID (not `377414509754`)
  - Ensure all tests pass, ask the user if questions arise.

---

## Notes

- All Lambda function source files are deployed **verbatim** from `instruction/day2/Day 2 source 2/Day 2 source/Lambda/`. No Python code is modified by this spec.
- Step Functions JSON definitions are deployed with ARN substitution only (hardcoded account IDs replaced with `data.aws_caller_identity.current.account_id`).
- The JOB_CONFIG extension items (task 4.5) effectively overwrite the Day 1 seed items with a superset of columns. This is intentional — the Day 2 items include all old and new attributes to avoid partial updates.
- SES sandbox mode requires manual verification of both sender and receiver email addresses before `Send_Mail` can deliver. This is documented in `infra/day2/README.md` and enforced by the Lambda logic filtering unverified addresses.
- EventBridge schedule (task 7) is optional and gated by `var.enable_schedule`. Default is `false`.
- The DynamoDB table names `NT_Accelarate_JOB_STATUS` and `NT_Acccelarate_WATERMARKTABLE` have intentional misspellings. Comments in `locals.tf` mark these as deliberate to prevent "helpful" corrections.

## Task Dependency Graph

```json
{
  "waves": [
    {
      "id": 0,
      "tasks": ["1", "2.1"]
    },
    {
      "id": 1,
      "tasks": ["2.2", "3.1", "4.1", "4.3"]
    },
    {
      "id": 2,
      "tasks": ["3.2", "4.2", "4.4"]
    },
    {
      "id": 3,
      "tasks": ["3.3", "4.5", "5.1", "6.1"]
    },
    {
      "id": 4,
      "tasks": ["5.2", "6.2"]
    },
    {
      "id": 5,
      "tasks": ["5.3", "6.3", "7.1", "8"]
    },
    {
      "id": 6,
      "tasks": ["7.2", "9"]
    }
  ]
}
```
