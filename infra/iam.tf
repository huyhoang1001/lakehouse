# iam.tf
# -----------------------------------------------------------------------------
# IAM role and policies for the NT Accelerate Glue jobs.
#
# Includes:
#   - aws_iam_role                   NT_Accelerate_GlueRole (task 3.1)
#   - aws_iam_role_policy_attachment AWSGlueServiceRole managed policy (task 3.2)
#
# Task 3.3 (inline scoped policy) will be added to this file in a later task.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "glue" {
  name = local.glue_role_name # "NT_Accelerate_GlueRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_scoped" {
  name = "NT_Accelerate_GlueRole_ScopedPolicy"
  role = aws_iam_role.glue.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.main.arn,
        ]
      },
      {
        Sid    = "S3ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [
          "${aws_s3_bucket.main.arn}/*",
        ]
      },
      {
        Sid    = "DynamoDBControlTables"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.ddb_job_config}",
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.ddb_job_log}",
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.ddb_job_status}",
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.ddb_watermark}",
        ]
      },
      {
        Sid    = "SecretsManagerGetSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Resource = [
          "${aws_secretsmanager_secret.rds_secret.arn}*",
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:*:*:*",
        ]
      },
    ]
  })
}
