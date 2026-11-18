# variables.tf — Day 2 module inputs

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket created in Day 1."
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the S3 bucket created in Day 1."
  type        = string
}

variable "glue_job_names" {
  description = "List of Glue job names from Day 1."
  type        = list(string)
}

variable "glue_database_name" {
  description = "Glue Data Catalog database name from Day 1."
  type        = string
}

variable "dynamodb_table_arns" {
  description = "Map of Day 1 DynamoDB table ARNs."
  type        = map(string)
}

variable "ses_sender_email" {
  description = "SES sender email address."
  type        = string
  default     = "sender@example.com"
}

variable "ses_receiver_emails" {
  description = "List of SES receiver email addresses."
  type        = list(string)
  default     = ["recipient@example.com"]
}

variable "enable_schedule" {
  description = "When true, create the EventBridge schedule rule."
  type        = bool
  default     = false
}

variable "sfn_log_retention_days" {
  description = "Retention period (days) for the Step Functions CloudWatch log groups."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to all Day 2 resources."
  type        = map(string)
  default = {
    Project   = "NT_Accelerate"
    ManagedBy = "Terraform"
  }
}
