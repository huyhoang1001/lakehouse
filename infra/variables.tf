# variables.tf
# -----------------------------------------------------------------------------
# All stack inputs.
#
# Required variables (bucket_name, db_username, db_password,
# source_artifacts_dir) have no default and must be supplied via a
# terraform.tfvars file or -var flags. RDS credentials are marked sensitive so
# they are never echoed in plan/apply output.
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources. Pinned to us-east-1 to match the lab's JDBC URL and watermark seed values."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique name of the S3 bucket that holds Glue scripts, shared libraries, raw landing files, data-lake output, Spark logs, and temp space."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars of lowercase letters, numbers, hyphens, or dots, and must start/end with a letter or number."
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
  description = "RDS instance class. SQL Server Express runs on db.t3.micro/small; do not pick a larger class without changing the license model."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB for the RDS instance (gp2)."
  type        = number
  default     = 20
}

variable "enable_flatfile_job" {
  description = "Set to true to create the optional flat-file (CSV/Excel/JSON/XML) extraction job (Req 10). Defaults to false so the RDS extraction jobs are unaffected."
  type        = bool
  default     = false
}

variable "run_date" {
  description = "Value passed to each Glue job as --p_run_date; used as the output date partition under lake/bronze/tickit/<table>/<run_date>/."
  type        = string
  default     = "2024-01-01"
}

variable "batch_id" {
  description = "Value passed to each Glue job as --p_batch_id; identifies the run batch in JOB_LOG entries."
  type        = number
  default     = 1
}

variable "source_artifacts_dir" {
  description = "Local path to the provided Day 1 source artifacts (the 'Day 1 source 3/Day 1 source' folder containing S3/ and the Glue scripts)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all taggable resources via the AWS provider default_tags."
  type        = map(string)
  default = {
    Project   = "NT_Accelerate"
    ManagedBy = "Terraform"
  }
}
