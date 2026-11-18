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
