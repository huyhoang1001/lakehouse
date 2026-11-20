# outputs.tf — Day 3 module outputs (Req 13.1)

# Delta + Redshift Glue job names created by Day 3.
output "glue_job_names" {
  description = "Day 3 Glue job names (six Delta jobs, plus six Redshift jobs when enable_redshift is true)."
  value = concat(
    [for name in sort(keys(local.delta_jobs)) : "jb_DW_Delta_Load_${name}"],
    var.enable_redshift ? [for name in sort(keys(local.redshift_jobs)) : "jb_DW_Redshift_Load_${name}"] : [],
  )
}

# Delta gold location written by the Delta jobs.
output "delta_gold_location" {
  description = "S3 location of the gold Delta tables."
  value       = local.lakehouse_location
}

# Redshift endpoint — null when the warehouse is disabled.
output "redshift_endpoint" {
  description = "Redshift cluster endpoint (host:port), or null when enable_redshift is false."
  value       = one(aws_redshift_cluster.this[*].endpoint)
}

# Redshift Glue connection name — null when the warehouse is disabled.
output "redshift_connection_name" {
  description = "Name of the Redshift Glue connection, or null when enable_redshift is false."
  value       = one(aws_glue_connection.conRedshift_tickit[*].name)
}

# Day 3 JOB_CONFIG row IDs, keyed by job name.
output "job_config_row_ids" {
  description = "Map of Day 3 Glue job name to its NT_Accelerate_JOB_CONFIG primary key."
  value = merge(
    { for name, job in local.delta_jobs : "jb_DW_Delta_Load_${name}" => job.id },
    var.enable_redshift ? { for name, job in local.redshift_jobs : "jb_DW_Redshift_Load_${name}" => job.id } : {},
  )
}
