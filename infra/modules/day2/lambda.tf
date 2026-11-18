# lambda.tf
# -----------------------------------------------------------------------------
# Task 3 — Package, upload, and deploy the nine Day 2 orchestration Lambda
# functions.
#
# The Python source files are deployed VERBATIM from the lab artifacts under
# instruction/day2/...; Terraform only packages and wires them (Req 2, Req 1.3).
# Every source file exposes `lambda_handler`, so the handler is
# "<function_name>.lambda_handler".
# -----------------------------------------------------------------------------

# Task 3.1 — one ZIP archive per Lambda function (Req 2.2).
# Output lands in the repo-root tmp/ directory, the same convention Day 1 uses
# for its Genericlib.zip (and the same directory .gitignore already excludes).
data "archive_file" "lambda" {
  for_each = toset(local.lambda_function_names)

  type        = "zip"
  source_file = "${local.lambda_source_dir}/${each.value}.py"
  output_path = "${path.module}/../../../tmp/${each.value}.zip"
}

# Task 3.2 — upload each ZIP to s3://<bucket>/lambda/<function>.zip (Req 2.4).
# The etag is the archive's output hash, so a change to a source file changes the
# object and re-triggers the Lambda update on the next apply (Req 2.5).
resource "aws_s3_object" "lambda" {
  for_each = toset(local.lambda_function_names)

  bucket = var.bucket_name
  key    = "${local.s3_lambda_prefix}${each.value}.zip"
  source = data.archive_file.lambda[each.value].output_path
  etag   = data.archive_file.lambda[each.value].output_md5
}

# Task 3.3 — the nine Lambda functions (Req 2.1, 2.3, 2.5).
# Code is loaded from the S3 object uploaded above; the role is the
# least-privilege NT_Accelerate_LambdaRole from iam.tf.
resource "aws_lambda_function" "this" {
  for_each = toset(local.lambda_function_names)

  function_name = each.value
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.9"
  handler       = "${each.value}.lambda_handler"
  timeout       = 60

  s3_bucket        = var.bucket_name
  s3_key           = aws_s3_object.lambda[each.value].key
  source_code_hash = data.archive_file.lambda[each.value].output_base64sha256

  environment {
    variables = {
      REGION = var.aws_region
    }
  }

  tags = var.tags
}
