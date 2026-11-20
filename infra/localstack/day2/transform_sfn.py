"""
Rewrite a shipped Day 2 master-job definition for the local harness.

Two changes, both local-only:

  1. Every `arn:aws:states:::glue:startJobRun.sync` state is pointed at a local
     Lambda instead. LocalStack's free tier cannot run Glue, so the real
     integration could never succeed locally. There are two ways to stand in
     for it, chosen by the caller:

       --callback  (default) `lambda:invoke.waitForTaskToken` of the bridge
                   (glue_bridge.py). The bridge queues the job and returns; the
                   execution stays paused on its task token until
                   run-glue-agent.sh has run the job for real with run-glue.sh
                   and resumed the execution. The job's own JOB_LOG /
                   JOB_STATUS writes are the real ones.
       --stub      plain `lambda:invoke` of the stub (glue_stub.py), which just
                   records SUCCEEDED rows itself. No Glue job runs, so it is
                   the quick way to exercise the orchestration alone.

     Either way the state's `Parameters.Arguments` move to `Payload`.

  2. Every hardcoded Lambda ARN
     (arn:aws:lambda:us-east-1:377414509754:function:<Name>:$LATEST) is
     rewritten to the ARN LocalStack actually assigned that function.

The Terraform module (infra/modules/day2/sfn.tf) performs only change 2 --
against the real account and region -- and deploys the Glue states verbatim.

Usage:
  transform_sfn.py <in.json> <out.json> <glue_target_arn> <function_arns.json>
                   [--callback | --stub]

where <function_arns.json> is
  {"NT_Accelerate_Read_Run_Type": "arn:aws:lambda:...", ...}

`glue_target_arn` is the ARN of whichever stand-in is selected.
"""
import json
import sys

GLUE_RESOURCE = "arn:aws:states:::glue:startJobRun.sync"
LAMBDA_RESOURCE = "arn:aws:states:::lambda:invoke"
CALLBACK_RESOURCE = "arn:aws:states:::lambda:invoke.waitForTaskToken"


def _short_name(arn):
    # arn:aws:lambda:us-east-1:377414509754:function:NT_Accelerate_Send_Mail:$LATEST
    return arn.split(":function:", 1)[1].split(":", 1)[0]


def _rewrite(states, target_arn, arns, callback):
    for state in states.values():
        if state.get("Resource") == GLUE_RESOURCE:
            # Keep the arguments the orchestrator computed; just route them to
            # the local stand-in instead of Glue.
            parameters = state.get("Parameters", {})
            payload = dict(parameters.get("Arguments", {}))
            if callback:
                # The Glue state carries JobName next to Arguments; the bridge
                # needs it (it is the script name) and the task token that makes
                # Step Functions wait for the agent.
                job_name = parameters.get("JobName")
                if job_name is not None:
                    payload["JobName"] = job_name
                payload["task_token.$"] = "$$.Task.Token"
                state["Resource"] = CALLBACK_RESOURCE
            else:
                state["Resource"] = LAMBDA_RESOURCE
            state["Parameters"] = {"FunctionName": target_arn, "Payload": payload}
        elif state.get("Resource") == LAMBDA_RESOURCE:
            state["Parameters"]["FunctionName"] = arns[_short_name(state["Parameters"]["FunctionName"])]

        for branch in state.get("Branches", []):
            _rewrite(branch["States"], target_arn, arns, callback)


def main():
    argv = [a for a in sys.argv[1:] if a not in ("--callback", "--stub")]
    callback = "--stub" not in sys.argv[1:]

    src, dst, target_arn, arns_path = argv[:4]
    with open(arns_path) as fh:
        arns = json.load(fh)
    with open(src) as fh:
        document = json.load(fh)

    _rewrite(document["States"], target_arn, arns, callback)

    with open(dst, "w") as fh:
        json.dump(document, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
