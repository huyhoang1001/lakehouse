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
