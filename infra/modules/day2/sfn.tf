# sfn.tf
# -----------------------------------------------------------------------------
# Task 5 — the three Day 2 Step Functions state machines.
#
# The lab ships each definition as JSON with the original account id
# (377414509754) and the Lambda version qualifier (:$LATEST) hardcoded into
# every Lambda invoke ARN. Terraform rewrites ONLY those two fragments so the
# definitions point at the Lambda functions this module deploys; the rest of
# each definition is deployed verbatim (Req 7.2–7.4).
#
# The definitions also reference Glue *job names* (e.g. "jb_Stg_Extract_Category")
# and the out-of-scope Lakehouse / Redshift jobs. Those names are not
# Terraform-managed, so they are intentionally left untouched (Req 7.6).
# -----------------------------------------------------------------------------

locals {
  # Logical state-machine name -> definition file on disk (Req 7.1). The names
  # match the lab's "Edit <name>.json" artifacts.
  sfn_def_files = {
    "NT_Accelerate_Datalake_Master_Job"   = "${local.sfn_def_dir}/Edit NT_Accelerate_Datalake_Master_Job.json"
    "NT_Accelerate_LakeHouse_Master_Job"  = "${local.sfn_def_dir}/Edit NT_Accelerate_LakeHouse_Master_Job.json"
    "NT_Accelerate_RedshiftDW_Master_Job" = "${local.sfn_def_dir}/Edit NT_Accelerate_RedshiftDW_Master_Job.json"
  }

  # Rewrite the hardcoded Lambda ARNs. After both replacements every Lambda
  # reference equals aws_lambda_function.this[<Name>].arn:
  #
  #   arn:aws:lambda:us-east-1:377414509754:function:NT_Accelerate_Read_Run_Type:$LATEST
  #     -> arn:aws:lambda:<region>:<account>:function:NT_Accelerate_Read_Run_Type
  #
  # `:$LATEST` only ever appears inside those ARNs, so stripping it globally is
  # safe. Capture the ARN by construction rather than by a per-function replace
  # chain; the explicit depends_on on the state machines below keeps creation
  # ordered after the functions.
  sfn_definitions = {
    for name, path in local.sfn_def_files :
    name => replace(
      replace(
        file(path),
        "arn:aws:lambda:us-east-1:377414509754:function:",
        "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:",
      ),
      ":$LATEST",
      "",
    )
  }
}

# Task 5.3 — one CloudWatch log group per state machine (Req 7.5).
resource "aws_cloudwatch_log_group" "sfn" {
  for_each = local.sfn_def_files

  name              = "/aws/states/${each.key}"
  retention_in_days = var.sfn_log_retention_days

  tags = var.tags
}

# Task 5.2 — the three STANDARD state machines (Req 7.1, 7.6).
resource "aws_sfn_state_machine" "this" {
  for_each = local.sfn_def_files

  name     = each.key
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = local.sfn_definitions[each.key]

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn[each.key].arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = var.tags

  # `definition` is built by string substitution rather than by referencing
  # aws_lambda_function ARNs, so declare the dependency explicitly to guarantee
  # the invoked functions exist first.
  depends_on = [aws_lambda_function.this]
}
