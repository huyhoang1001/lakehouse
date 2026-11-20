# variables.tf — Day 3 module inputs
# -----------------------------------------------------------------------------
# Day 1 and Day 2 outputs arrive as input variables (via the root main.tf);
# no terraform_remote_state is used. Everything the Day 3 transform layer
# needs is either derived from a Day 1/Day 2 output or is a Day 3-specific
# input such as the Redshift cluster settings.
# -----------------------------------------------------------------------------

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

variable "glue_database_name" {
  description = "Glue Data Catalog database name from Day 1 (\"tickit\")."
  type        = string
}

variable "glue_role_name" {
  description = "Name of the Day 1 Glue IAM role, so Day 3 can attach the additional Redshift/catalog policy to it by name."
  type        = string
}

variable "glue_role_arn" {
  description = "ARN of the Day 1 Glue IAM role, used as the execution role for the Day 3 Glue jobs."
  type        = string
}

variable "job_config_table_name" {
  description = "Name of the Day 1 NT_Accelerate_JOB_CONFIG table, from Day 1 dynamodb_table_names[\"job_config\"]."
  type        = string
}

variable "master_job_config_table_name" {
  description = "Name of the Day 2 NT_Accelerate_MASTER_JOB_CONFIG table, from Day 2 dynamodb_table_names[\"master_job_config\"]."
  type        = string
}

variable "run_date" {
  description = "Value passed to each Day 3 Glue job as --p_run_date; also the bronze partition folder read by the transform jobs."
  type        = string
  default     = "2024-01-01"
}

variable "batch_id" {
  description = "Value passed to each Day 3 Glue job as --p_batch_id."
  type        = number
  default     = 1
}

# --- Redshift -----------------------------------------------------------------

variable "enable_redshift" {
  description = "When true (default), provision the Amazon Redshift cluster, connection, secret, and the six Redshift load Glue jobs. Set to false for a Delta-only Day 3 that bills nothing for the warehouse."
  type        = bool
  default     = true
}

variable "redshift_database_name" {
  description = "Redshift database name that holds the target tables."
  type        = string
  default     = "tickit"
}

variable "redshift_master_username" {
  description = "Redshift master username."
  type        = string
  default     = "admin"
}

variable "redshift_master_password" {
  description = "Redshift master password. Must satisfy the Redshift password policy."
  type        = string
  sensitive   = true
}

variable "redshift_node_type" {
  description = "Redshift node type. dc2.large is the cheapest single-node option."
  type        = string
  default     = "dc2.large"
}

variable "redshift_number_of_nodes" {
  description = "Number of Redshift nodes. 1 is the minimum."
  type        = number
  default     = 1
}

variable "redshift_publicly_accessible" {
  description = "Whether the Redshift cluster gets a public IP. Not required for Glue-in-VPC access; defaults to false."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all Day 3 resources."
  type        = map(string)
  default = {
    Project   = "NT_Accelerate"
    ManagedBy = "Terraform"
  }
}
