# outputs.tf
# -----------------------------------------------------------------------------
# Root outputs — re-exported from child modules.
# -----------------------------------------------------------------------------

output "s3_bucket_name" {
  description = "Name of the S3 bucket."
  value       = module.day1.s3_bucket_name
}

output "rds_endpoint" {
  description = "JDBC URL of the RDS SQL Server Express instance."
  value       = module.day1.rds_endpoint
}

output "glue_job_names" {
  description = "All provisioned Glue job names."
  value       = module.day1.glue_job_names
}

output "glue_database_name" {
  description = "Glue Data Catalog database name."
  value       = module.day1.glue_database_name
}

output "crawler_name" {
  description = "Glue crawler name."
  value       = module.day1.crawler_name
}

output "connection_name" {
  description = "Glue JDBC connection name."
  value       = module.day1.connection_name
}

output "dynamodb_table_names" {
  description = "Day 1 DynamoDB table names (intentional typos preserved)."
  value       = module.day1.dynamodb_table_names
}

output "secret_arn" {
  description = "Secrets Manager secret ARN."
  value       = module.day1.secret_arn
}

output "secret_name" {
  description = "Secrets Manager secret name."
  value       = module.day1.secret_name
}

# --- Day 3 (Delta Lake gold + Redshift warehouse) ----------------------------

output "day3_glue_job_names" {
  description = "Day 3 Glue job names (Delta + Redshift)."
  value       = module.day3.glue_job_names
}

output "delta_gold_location" {
  description = "S3 location of the gold Delta tables written by the Delta load jobs."
  value       = module.day3.delta_gold_location
}

output "redshift_endpoint" {
  description = "Redshift cluster endpoint (host:port), or null when enable_redshift is false."
  value       = module.day3.redshift_endpoint
}

output "redshift_connection_name" {
  description = "Name of the Redshift Glue connection, or null when enable_redshift is false."
  value       = module.day3.redshift_connection_name
}

output "day3_job_config_row_ids" {
  description = "Map of Day 3 Glue job name to its NT_Accelerate_JOB_CONFIG primary key."
  value       = module.day3.job_config_row_ids
}
