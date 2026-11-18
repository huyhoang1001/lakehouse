"""
Rewrite a shipped Day 2 master-job definition for the local harness.

Two changes, both local-only:

  1. Every `arn:aws:states:::glue:startJobRun.sync` state becomes a
     `lambda:invoke` of the local stub (glue_stub.py). LocalStack's free tier
     cannot run Glue, so the real integration could never succeed locally; the
     stub records the same JOB_LOG / JOB_STATUS rows instead.

  2. Every hardcoded Lambda ARN
     (arn:aws:lambda:us-east-1:377414509754:function:<Name>:$LATEST) is
     rewritten to the ARN LocalStack actually assigned that function.

The Terraform module (infra/modules/day2/sfn.tf) performs only change 2 --
against the real account and region -- and deploys the Glue states verbatim.

Usage:
  transform_sfn.py <in.json> <out.json> <stub_arn> <function_arns.json>

where <function_arns.json> is
  {"NT_Accelerate_Read_Run_Type": "arn:aws:lambda:...", ...}
"""
import json
import sys

GLUE_RESOURCE = "arn:aws:states:::glue:startJobRun.sync"
LAMBDA_RESOURCE = "arn:aws:states:::lambda:invoke"


def _short_name(arn):
    # arn:aws:lambda:us-east-1:377414509754:function:NT_Accelerate_Send_Mail:$LATEST
    return arn.split(":function:", 1)[1].split(":", 1)[0]


def _rewrite(states, stub_arn, arns):
    for state in states.values():
        if state.get("Resource") == GLUE_RESOURCE:
            # Keep the arguments the orchestrator computed; just route them to
            # the stub instead of Glue.
            arguments = state.get("Parameters", {}).get("Arguments", {})
            state["Resource"] = LAMBDA_RESOURCE
            state["Parameters"] = {"FunctionName": stub_arn, "Payload": arguments}
        elif state.get("Resource") == LAMBDA_RESOURCE:
            state["Parameters"]["FunctionName"] = arns[_short_name(state["Parameters"]["FunctionName"])]

        for branch in state.get("Branches", []):
            _rewrite(branch["States"], stub_arn, arns)


def main():
    src, dst, stub_arn, arns_path = sys.argv[1:5]
    with open(arns_path) as fh:
        arns = json.load(fh)
    with open(src) as fh:
        document = json.load(fh)

    _rewrite(document["States"], stub_arn, arns)

    with open(dst, "w") as fh:
        json.dump(document, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
