# s3.tf
# -----------------------------------------------------------------------------
# Core S3 bucket for the NT Accelerate lakehouse.
#
# Includes:
#   - aws_s3_bucket                                 (task 2.1)
#   - aws_s3_bucket_versioning                      (task 2.2)
#   - aws_s3_bucket_public_access_block             (task 2.2)
#   - aws_s3_bucket_server_side_encryption_configuration (task 2.2)
#
# Object uploads (scripts, libraries, raw files) are added in tasks 2.3–2.6.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "main" {
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# task 2.3 — Upload the 8 Glue Python scripts to glue_script/
# -----------------------------------------------------------------------------

locals {
  glue_scripts = toset([
    "jb_Stg_Extract_Category.py",
    "jb_Stg_Extract_Date.py",
    "jb_Stg_Extract_Event.py",
    "jb_Stg_Extract_Listing.py",
    "jb_Stg_Extract_Sales.py",
    "jb_Stg_Extract_Users.py",
    "jb_Stg_Extract_Venue.py",
    "jb_Stg_Extract_ExcelFile.py",
  ])
}

resource "aws_s3_object" "glue_scripts" {
  for_each = local.glue_scripts

  bucket = aws_s3_bucket.main.id
  key    = "glue_script/${each.value}"
  source = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/Glue script/${each.value}"
  etag   = filemd5("${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/Glue script/${each.value}")

  depends_on = [aws_s3_bucket.main]
}
