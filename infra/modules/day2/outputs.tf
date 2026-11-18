# outputs.tf — Day 2 module outputs (Req 1.5)

# Lambda function ARNs, keyed by function name (Req 1.5).
output "lambda_function_arns" {
  description = "Map of orchestration Lambda function name to ARN."
  value       = { for name, fn in aws_lambda_function.this : name => fn.arn }
}

# Step Functions state machine ARNs, keyed by machine name (Req 1.5).
output "step_function_arns" {
  description = "Map of master-job state machine name to ARN."
  value       = { for name, sm in aws_sfn_state_machine.this : name => sm.arn }
}

# Day 2 DynamoDB control tables (Req 1.5).
output "dynamodb_table_names" {
  description = "Names of the Day 2 control tables."
  value = {
    master_job_config = aws_dynamodb_table.master_job_config.name
    mail_config       = aws_dynamodb_table.mail_config.name
  }
}

# SES identities (Req 1.5).
output "ses_sender_identity_arn" {
  description = "ARN of the verified SES sender identity."
  value       = aws_ses_email_identity.sender.arn
}

output "ses_receiver_identity_arns" {
  description = "Map of receiver email address to verified SES identity ARN."
  value       = { for email, identity in aws_ses_email_identity.receiver : email => identity.arn }
}

# EventBridge rule ARN, only when the schedule is enabled (Req 1.5).
output "eventbridge_rule_arn" {
  description = "ARN of the daily trigger rule, or null when var.enable_schedule is false."
  value       = one(aws_cloudwatch_event_rule.daily[*].arn)
}

# Step Functions CloudWatch log groups (Req 7.5).
output "step_function_log_group_names" {
  description = "Map of state machine name to its CloudWatch log group name."
  value       = { for name, lg in aws_cloudwatch_log_group.sfn : name => lg.name }
}
