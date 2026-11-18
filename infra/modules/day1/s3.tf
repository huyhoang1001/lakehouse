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
  # force_destroy removes all object versions automatically on terraform destroy,
  # so the bucket can be deleted without a manual "aws s3 rm --recursive" step.
  force_destroy = true
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

# -----------------------------------------------------------------------------
# task 2.4 — Zip Genericlib.py and upload both library files to library/
# -----------------------------------------------------------------------------

data "archive_file" "genericlib" {
  type        = "zip"
  source_file = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/library/Genericlib/Genericlib.py"
  output_path = "${path.module}/../../../tmp/Genericlib.zip"
}

resource "aws_s3_object" "genericlib_zip" {
  bucket = aws_s3_bucket.main.id
  key    = "library/Genericlib.zip"
  source = data.archive_file.genericlib.output_path
  etag   = data.archive_file.genericlib.output_md5

  depends_on = [aws_s3_bucket.main]
}

resource "aws_s3_object" "openpyxl" {
  bucket = aws_s3_bucket.main.id
  key    = "library/openpyxl-3.0.10.tar.gz"
  source = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/library/openpyxl-3.0.10.tar.gz"
  etag   = filemd5("${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/library/openpyxl-3.0.10.tar.gz")

  depends_on = [aws_s3_bucket.main]
}

# -----------------------------------------------------------------------------
# task 2.5 — Upload raw sample files to raw/<type>/
# -----------------------------------------------------------------------------

resource "aws_s3_object" "raw_csv" {
  bucket = aws_s3_bucket.main.id
  key    = "raw/csv/SalesEvent.csv"
  source = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/csv/SalesEvent.csv"
  etag   = filemd5("${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/csv/SalesEvent.csv")

  depends_on = [aws_s3_bucket.main]
}

resource "aws_s3_object" "raw_excel" {
  bucket = aws_s3_bucket.main.id
  key    = "raw/excel/SalesEvent.xlsx"
  source = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/excel/SalesEvent.xlsx"
  etag   = filemd5("${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/excel/SalesEvent.xlsx")

  depends_on = [aws_s3_bucket.main]
}

resource "aws_s3_object" "raw_json" {
  bucket = aws_s3_bucket.main.id
  key    = "raw/json/user.json"
  source = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/json/user.json"
  etag   = filemd5("${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/json/user.json")

  depends_on = [aws_s3_bucket.main]
}

resource "aws_s3_object" "raw_xml" {
  bucket = aws_s3_bucket.main.id
  key    = "raw/xml/customer.xml"
  source = "${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/xml/customer.xml"
  etag   = filemd5("${var.source_artifacts_dir}/Day 1 source 3/Day 1 source/S3/raw/xml/customer.xml")

  depends_on = [aws_s3_bucket.main]
}

# -----------------------------------------------------------------------------
# task 2.6 — Zero-byte prefix objects
# -----------------------------------------------------------------------------

resource "aws_s3_object" "prefix_lake" {
  bucket     = aws_s3_bucket.main.id
  key        = "lake/bronze/tickit/"
  content    = ""
  depends_on = [aws_s3_bucket.main]
}

resource "aws_s3_object" "prefix_spark_history_logs" {
  bucket     = aws_s3_bucket.main.id
  key        = "sparkHistoryLogs/"
  content    = ""
  depends_on = [aws_s3_bucket.main]
}

resource "aws_s3_object" "prefix_temporary" {
  bucket     = aws_s3_bucket.main.id
  key        = "temporary/"
  content    = ""
  depends_on = [aws_s3_bucket.main]
}
