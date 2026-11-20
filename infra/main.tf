# main.tf
# -----------------------------------------------------------------------------
# Root module — wires the Day 1 ingestion module and the Day 2 orchestration
# module together. Day 1 outputs are passed directly to Day 2 as inputs,
# so no remote state is needed.
# -----------------------------------------------------------------------------

module "day1" {
  source = "./modules/day1"

  aws_region           = var.aws_region
  bucket_name          = var.bucket_name
  db_username          = var.db_username
  db_password          = var.db_password
  db_instance_class    = var.db_instance_class
  db_allocated_storage = var.db_allocated_storage
  enable_flatfile_job  = var.enable_flatfile_job
  run_date             = var.run_date
  batch_id             = var.batch_id
  source_artifacts_dir = var.source_artifacts_dir
  tags                 = var.tags
}

module "day2" {
  source = "./modules/day2"

  aws_region          = var.aws_region
  bucket_name         = module.day1.s3_bucket_name
  bucket_arn          = module.day1.s3_bucket_arn
  glue_job_names      = module.day1.glue_job_names
  glue_database_name  = module.day1.glue_database_name
  dynamodb_table_arns = module.day1.dynamodb_table_arns
  ses_sender_email    = var.ses_sender_email
  ses_receiver_emails = var.ses_receiver_emails
  enable_schedule     = var.enable_schedule
  tags                = var.tags
}

# Day 3 transform module — Delta Lake (gold) + Amazon Redshift warehouse.
# It consumes Day 1 and Day 2 outputs as inputs; it never edits their files.
module "day3" {
  source = "./modules/day3"

  aws_region  = var.aws_region
  bucket_name = module.day1.s3_bucket_name
  bucket_arn  = module.day1.s3_bucket_arn

  glue_database_name = module.day1.glue_database_name
  # Day 1 exports the Glue role ARN; the role name (needed to attach the Day 3
  # policy) is derived from it, so the Day 1 module stays untouched.
  glue_role_arn  = module.day1.glue_role_arn
  glue_role_name = element(split("/", module.day1.glue_role_arn), 1)

  job_config_table_name        = module.day1.dynamodb_table_names["job_config"]
  master_job_config_table_name = module.day2.dynamodb_table_names["master_job_config"]

  run_date = var.run_date
  batch_id = var.batch_id

  enable_redshift              = var.enable_redshift
  redshift_master_username     = var.redshift_master_username
  redshift_master_password     = var.redshift_master_password
  redshift_database_name       = var.redshift_database_name
  redshift_node_type           = var.redshift_node_type
  redshift_number_of_nodes     = var.redshift_number_of_nodes
  redshift_publicly_accessible = var.redshift_publicly_accessible

  tags = var.tags
}
