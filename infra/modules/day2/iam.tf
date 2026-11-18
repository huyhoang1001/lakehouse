# iam.tf — Day 2 module IAM roles and policies
# -----------------------------------------------------------------------------
# Task 2.1 — NT_Accelerate_LambdaRole
#   Trust: lambda.amazonaws.com
#   Inline scoped policy (refs Req 3):
#     - DynamoDB CRUD on the six control tables
#     - glue:StartJobRun / glue:GetJobRun on all Glue jobs
#     - ses:SendEmail / ses:GetIdentityVerificationAttributes
#     - CloudWatch Logs
#   No AWS managed policy is attached — least privilege (Req 3.6).
#
# Task 2.2 — NT_Accelerate_StepFunctionsRole
#   Trust: states.amazonaws.com
#   Inline scoped policy (refs Req 4):
#     - lambda:InvokeFunction on the nine orchestration Lambda functions
#     - glue:StartJobRun / glue:GetJobRun on all Glue jobs
#     - CloudWatch Logs delivery permissions for Step Functions logging
# -----------------------------------------------------------------------------

locals {
  # The six DynamoDB control tables the Lambda role may CRUD (Req 3.2).
  # The four Day 1 tables arrive as full ARNs via var.dynamodb_table_arns.
  # The two Day 2 tables are owned by this module; their ARNs are constructed
  # from the name locals so this policy stays independent of the DynamoDB
  # resource creation order (the tables are created in a later task).
  lambda_dynamodb_table_arns = concat(
    values(var.dynamodb_table_arns),
    [
      "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.ddb_master_job_config}",
      "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.ddb_mail_config}",
    ],
  )

  # ARNs of the nine orchestration Lambda functions the Step Functions role may
  # invoke (Req 4.2). Constructed from the name locals so this policy stays
  # independent of the Lambda resource creation order (the functions are created
  # in a later task).
  sfn_lambda_function_arns = [
    for name in local.lambda_function_names :
    "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${name}"
  ]
}

# Task 2.1 — IAM role assumed by all nine orchestration Lambda functions (Req 3.1)
resource "aws_iam_role" "lambda" {
  name = "NT_Accelerate_LambdaRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Task 2.1 — Inline scoped policy attached to the Lambda role (Req 3.2–3.5)
resource "aws_iam_role_policy" "lambda_scoped" {
  name = "NT_Accelerate_LambdaRole_ScopedPolicy"
  role = aws_iam_role.lambda.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Resource = local.lambda_dynamodb_table_arns
      },
      {
        Sid    = "GlueJobRuns"
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:*:job/*",
        ]
      },
      {
        Sid    = "SESNotifications"
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:GetIdentityVerificationAttributes",
        ]
        Resource = ["*"]
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

# Task 2.2 — IAM role assumed by the three Step Functions state machines (Req 4.1)
resource "aws_iam_role" "step_functions" {
  name = "NT_Accelerate_StepFunctionsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Task 2.2 — Inline scoped policy attached to the Step Functions role (Req 4.2–4.4)
resource "aws_iam_role_policy" "step_functions_scoped" {
  name = "NT_Accelerate_StepFunctionsRole_ScopedPolicy"
  role = aws_iam_role.step_functions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeOrchestrationLambdas"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
        ]
        Resource = local.sfn_lambda_function_arns
      },
      {
        Sid    = "GlueJobRuns"
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:*:job/*",
        ]
      },
      {
        Sid    = "CloudWatchLogsDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = ["*"]
      },
    ]
  })
}
