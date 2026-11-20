# s3.tf
# -----------------------------------------------------------------------------
# Day 3 S3 objects in the Day 1 bucket:
#   - the gold Delta prefix `lake/gold/tickit/` (Req 2.1)
#   - the Delta runtime jar at `library/delta-spark_2.13-4.1.0.jar` (Req 2.2–2.4)
#
# `temporary/` and `lake/bronze/tickit/` are already created by the Day 1 module,
# so they are intentionally NOT re-created here — two modules managing the same
# S3 key would fight on destroy.
# -----------------------------------------------------------------------------

# Req 2.1 — zero-byte marker for the gold Delta prefix.
resource "aws_s3_object" "gold_prefix" {
  bucket  = var.bucket_name
  key     = local.s3_gold_prefix
  content = ""
}

# Req 2.2–2.4 — upload the Delta runtime jar. `etag = filemd5(...)` re-uploads
# whenever the source file changes on the next apply.
resource "aws_s3_object" "delta_jar" {
  bucket = var.bucket_name
  key    = local.delta_jar_key
  source = local.delta_jar_source
  etag   = filemd5(local.delta_jar_source)
}
