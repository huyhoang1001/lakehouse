# iam.tf
# -----------------------------------------------------------------------------
# Extends the Day 1 Glue execution role with the Day 3 permissions.
#
# The Day 1 role (NT_Accelerate_GlueRole) already allows:
#   - s3:GetObject/PutObject/DeleteObject on the whole bucket,
#   - secretsmanager:GetSecretValue on the RDS secret,
#   - the AWSGlueServiceRole managed policy.
# Day 3 adds a dedicated inline policy for the Delta gold write path and, when
# Redshift is enabled, read access to the Redshift secret plus the Glue Data
# Catalog actions the transform jobs need (Req 9). The role is referenced by
# name; no file under infra/modules/day1/ is modified (Req 1.3).
# -----------------------------------------------------------------------------

locals {
  # Redshift secret read statement — only when the secret exists (Req 9.2).
  # The splat keeps the reference valid when count == 0.
  redshift_secret_statement = var.enable_redshift ? [{
    Sid    = "RedshiftSecretRead"
    Effect = "Allow"
    Action = ["secretsmanager:GetSecretValue"]
    Resource = [
      for arn in aws_secretsmanager_secret.redshift_secret[*].arn : "${arn}*"
    ]
  }] : []

  glue_day3_statements = concat(
    [
      {
        Sid    = "S3LakehouseListBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [
          var.bucket_arn,
        ]
      },
      {
        # Read bronze (the transform sources) and the temporary staging area.
        Sid    = "S3BronzeRead"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${var.bucket_arn}/lake/bronze/*",
          "${var.bucket_arn}/temporary/*",
        ]
      },
      {
        # Write the Delta gold tables and the Redshift COPY staging objects.
        Sid    = "S3GoldWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [
          "${var.bucket_arn}/lake/gold/*",
          "${var.bucket_arn}/temporary/*",
        ]
      },
      {
        Sid    = "GlueDataCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = ["*"]
      },
    ],
    local.redshift_secret_statement,
  )
}

resource "aws_iam_role_policy" "glue_day3" {
  name = "NT_Accelerate_GlueRole_Day3Policy"
  role = var.glue_role_name # Day 1 role, referenced by name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.glue_day3_statements
  })
}
