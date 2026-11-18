# variables.tf
# -----------------------------------------------------------------------------
# Root inputs — covers all variables needed by both the Day 1 and Day 2 modules.
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources. Pinned to us-east-1 to match the lab's JDBC URL and watermark seed values."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique name of the S3 bucket used by both Day 1 and Day 2."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, hyphens, dots)."
  }
}

variable "db_username" {
  description = "Master username for the RDS SQL Server Express instance."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Master password for the RDS SQL Server Express instance."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB for the RDS instance."
  type        = number
  default     = 20
}

variable "enable_flatfile_job" {
  description = "Set to true to create the optional flat-file Glue extraction job."
  type        = bool
  default     = false
}

variable "run_date" {
  description = "Value passed to each Glue job as --p_run_date."
  type        = string
  default     = "2024-01-01"
}

variable "batch_id" {
  description = "Value passed to each Glue job as --p_batch_id."
  type        = number
  default     = 1
}

variable "source_artifacts_dir" {
  description = "Local path to the folder that contains 'Day 1 source 3' (the Day 1 module appends 'Day 1 source 3/Day 1 source/...' for the S3 assets and Glue scripts)."
  type        = string
}

# Day 2 variables

variable "ses_sender_email" {
  description = "Email address used as the SES sender for Day 2 job-status notifications."
  type        = string
  default     = "sender@example.com"
}

variable "ses_receiver_emails" {
  description = "List of email addresses that receive Day 2 job-status notifications."
  type        = list(string)
  default     = ["recipient@example.com"]
}

variable "enable_schedule" {
  description = "When true, create the EventBridge rule that triggers the Day 2 master job on a schedule."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to all taggable resources."
  type        = map(string)
  default = {
    Project   = "NT_Accelerate"
    ManagedBy = "Terraform"
  }
}
