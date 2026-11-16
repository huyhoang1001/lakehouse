# outputs.tf
# -----------------------------------------------------------------------------
# Stack outputs for Console verification (Req 11).
#
# Values are null placeholders until the corresponding resources are created in
# later tasks. Each output will be wired to the real resource attribute once
# the resource block exists (e.g. aws_s3_bucket, aws_db_instance, etc.).
# -----------------------------------------------------------------------------

output "s3_bucket_name" {
  description = "Name of the S3 bucket holding Glue scripts, libraries, raw samples, bronze-layer Parquet, Spark logs, and temp space."
  value       = null
}

output "rds_endpoint" {
  description = "JDBC URL of the RDS SQL Server Express instance: jdbc:sqlserver://<endpoint>:1433;databaseName=tickit"
  value       = "jdbc:sqlserver://${aws_db_instance.rds.address}:1433;databaseName=tickit"
}

output "glue_job_names" {
  description = "List of all provisioned Glue extraction job names (6 full-load + 1 incremental Sales; excludes the optional flat-file job)."
  value       = null
}

output "glue_database_name" {
  description = "Name of the Glue Data Catalog database that holds the crawled Tickit tables (tickit_dbo_*)."
  value       = null
}

output "crawler_name" {
  description = "Name of the Glue crawler that populates the Tickit catalog tables."
  value       = null
}

output "connection_name" {
  description = "Name of the Glue JDBC connection used to reach the RDS SQL Server instance."
  value       = null
}

output "dynamodb_table_names" {
  description = "Map of logical key to DynamoDB table name (spellings match Genericlib.py exactly, including intentional typos)."
  value       = null
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS JDBC connection credentials."
  value       = null
}

output "secret_name" {
  description = "Name of the Secrets Manager secret (SQLSource_Database_Connection_Info)."
  value       = null
}
