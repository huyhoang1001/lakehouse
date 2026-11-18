# outputs.tf — Day 1 module outputs

output "s3_bucket_name" {
  description = "Name of the S3 bucket."
  value       = aws_s3_bucket.main.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket."
  value       = aws_s3_bucket.main.arn
}

output "rds_endpoint" {
  description = "JDBC URL for the RDS SQL Server Express instance."
  value       = "jdbc:sqlserver://${aws_db_instance.rds.address}:1433;databaseName=tickit"
}

output "glue_job_names" {
  description = "All provisioned Glue job names."
  value = concat(
    sort(keys(aws_glue_job.full_load)),
    [aws_glue_job.sales.name]
  )
}

output "glue_database_name" {
  description = "Glue Data Catalog database name."
  value       = aws_glue_catalog_database.tickit.name
}

output "crawler_name" {
  description = "Glue crawler name."
  value       = aws_glue_crawler.rds_tickit.name
}

output "connection_name" {
  description = "Glue JDBC connection name."
  value       = aws_glue_connection.conRDS_tickit.name
}

output "dynamodb_table_arns" {
  description = "Map of logical key to DynamoDB table ARN."
  value = {
    job_config = aws_dynamodb_table.job_config.arn
    job_log    = aws_dynamodb_table.job_log.arn
    job_status = aws_dynamodb_table.job_status.arn
    watermark  = aws_dynamodb_table.watermark.arn
  }
}

output "dynamodb_table_names" {
  description = "Map of logical key to DynamoDB table name (intentional typos preserved)."
  value = {
    job_config = aws_dynamodb_table.job_config.name
    job_log    = aws_dynamodb_table.job_log.name
    job_status = aws_dynamodb_table.job_status.name
    watermark  = aws_dynamodb_table.watermark.name
  }
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.rds_secret.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.rds_secret.name
}

output "glue_role_arn" {
  description = "ARN of the Glue IAM role."
  value       = aws_iam_role.glue.arn
}
