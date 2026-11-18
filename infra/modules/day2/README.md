# Day 2 — Orchestration Module

Terraform for the NT Accelerate Day 2 orchestration layer: nine orchestration
Lambda functions, three Step Functions master jobs, two DynamoDB control
tables, SES notification identities, and an optional daily EventBridge trigger.

Results from Day 1 (bucket, Glue job names, DynamoDB table ARNs) are passed in
as module inputs — this module is never applied on its own. Apply it through
the root module in `infra/`.

## Resources

| Resource | Name |
| --- | --- |
| Lambda functions | `NT_Accelerate_*` (9) |
| State machines | `NT_Accelerate_Datalake_Master_Job`, `NT_Accelerate_LakeHouse_Master_Job`, `NT_Accelerate_RedshiftDW_Master_Job` |
| DynamoDB tables | `NT_Accelerate_MASTER_JOB_CONFIG`, `NT_Accelerate_Mail_Config` |
| EventBridge rule | `NT_Accelerate_Daily_Trigger` (only when `enable_schedule = true`) |

The `NT_Accelerate_JOB_CONFIG` rows are rewritten with a superset of the Day 1
and Day 2 columns so `NT_Accelerate_Is_Allow_Running` can read every field it
needs.

Step Function definitions are taken verbatim from the lab artifacts; only the
hardcoded account id and the `:$LATEST` Lambda qualifier are substituted.

## SES Configuration

`NT_Accelerate_Send_Mail` sends job-status email through Amazon SES. In the SES
sandbox (the default for a new account), **both** the sender and every receiver
address must be verified before any message is delivered:

1. Terraform creates the identities (`aws_ses_email_identity`) for the sender
   and each receiver, which triggers a verification email to each address.
2. **Each address owner must open that email and click the verification link.**
   Terraform cannot do this step.
3. Only after verification does `Send_Mail` include an address in the message.
   The Lambda calls `ses:GetIdentityVerificationAttributes` and drops any
   address whose status is not `Success`, so an unverified recipient is simply
   skipped rather than causing the run to fail.

The sender and receivers come from two root variables:

```hcl
ses_sender_email    = "sender@example.com"
ses_receiver_emails = ["recipient@example.com"]
```

While the account is in the sandbox, mail can only be sent to verified
addresses, and the sender must also be verified. Moving out of the sandbox
(requesting production access) removes those restrictions.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `aws_region` | AWS region. | — |
| `bucket_name` / `bucket_arn` | Day 1 S3 bucket. | — |
| `glue_job_names` | Day 1 Glue job names. | — |
| `glue_database_name` | Day 1 Glue catalog database. | — |
| `dynamodb_table_arns` | Day 1 table ARNs, keyed `job_config` / `job_log` / `job_status` / `watermark`. | — |
| `ses_sender_email` | SES sender address. | `sender@example.com` |
| `ses_receiver_emails` | SES receiver addresses. | `["recipient@example.com"]` |
| `enable_schedule` | Create the daily EventBridge rule. | `false` |
| `sfn_log_retention_days` | Retention for the Step Functions log groups. | `7` |
| `tags` | Tags applied to all resources. | `{ Project = "NT_Accelerate", ManagedBy = "Terraform" }` |
