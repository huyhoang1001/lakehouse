# eventbridge.tf
# -----------------------------------------------------------------------------
# Task 7 — optional EventBridge schedule that starts the Datalake (staging)
# Master Job once a day. Everything here is gated by var.enable_schedule so a
# default apply creates no schedule (Req 12, default false).
# -----------------------------------------------------------------------------

# Task 7.1 — daily trigger rule (Req 12.1).
resource "aws_cloudwatch_event_rule" "daily" {
  count = var.enable_schedule ? 1 : 0

  name                = "NT_Accelerate_Daily_Trigger"
  description         = "Starts the Datalake (staging) Master Job daily at 08:00 UTC."
  schedule_expression = "cron(0 8 * * ? *)"

  tags = var.tags
}

# Task 7.2 — IAM role EventBridge assumes to start the state machine (Req 12.2).
resource "aws_iam_role" "eventbridge" {
  count = var.enable_schedule ? 1 : 0

  name = "NT_Accelerate_EventBridgeRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Task 7.2 — scope the role to starting only the staging Master Job (Req 12.2).
resource "aws_iam_role_policy" "eventbridge_start_execution" {
  count = var.enable_schedule ? 1 : 0

  name = "NT_Accelerate_EventBridgeRole_StartExecution"
  role = aws_iam_role.eventbridge[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartStagingMasterJob"
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.this["NT_Accelerate_Datalake_Master_Job"].arn
      }
    ]
  })
}

# Task 7.2 — the rule's target is the staging Master Job (Req 12.2).
resource "aws_cloudwatch_event_target" "staging_master_job" {
  count = var.enable_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.daily[0].name
  target_id = "NT_Accelerate_Datalake_Master_Job"
  arn       = aws_sfn_state_machine.this["NT_Accelerate_Datalake_Master_Job"].arn
  role_arn  = aws_iam_role.eventbridge[0].arn
}
