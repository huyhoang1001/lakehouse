# Day 3 — Lakehouse Transform (Delta Lake + Amazon Redshift)

Day 3 completes the medallion pipeline. It turns the Day 1 **bronze** Parquet into
**gold** Delta Lake tables and an Amazon Redshift warehouse, driven by the two
data-warehouse master jobs that the Day 2 module already deploys.

This module (`infra/modules/day3/`) consumes Day 1 and Day 2 outputs as input
variables and does **not** modify any file under `infra/modules/day1/` or
`infra/modules/day2/`.

## What it creates

| Group | Resources |
|-------|-----------|
| Storage & runtime | gold prefix `lake/gold/tickit/`, Delta runtime jar at `library/delta-spark_2.13-4.1.0.jar` |
| Delta jobs | `jb_DW_Delta_Load_{DateDim,VenueDim,CategoryDim,UserDim,EventDim,SalesFact}` → Delta tables |
| Redshift | `aws_redshift_cluster` (`tickit`), subnet group, security groups, `conRedshift_tickit` Glue connection, secret |
| Redshift jobs | `jb_DW_Redshift_Load_{DateDim,VenueDim,CategoryDim,UserDim,EventDim,SalesFact}` → `dim_*` / `fact_sales` |
| Control rows | 12 `NT_Accelerate_JOB_CONFIG` rows (IDs 8–19) + `NT_Accelerate_MASTER_JOB_CONFIG` rows `ID=2`, `ID=3` |
| IAM | inline policy on the Day 1 Glue role (gold write, Redshift secret read, Glue catalog) |

The three master state machines themselves are deployed by Day 2 and are not
re-deployed here.

## Cost warning

**The Redshift cluster bills hourly.** Keep `enable_redshift = false` (or run
`terraform destroy`) whenever the lab is idle. `skip_final_snapshot = true` keeps
teardown clean.

## Required run order

Run the master jobs in this order — the staging gate is enforced by
`NT_Accelerate_Check_Staging_Master_Job_Status`:

1. **Staging** — `NT_Accelerate_Datalake_Master_Job` (master job `ID=1`, Day 2).
   Extracts RDS Tickit → bronze Parquet.
2. **LakeHouse** — `NT_Accelerate_LakeHouse_Master_Job` (`ID=2`).
   bronze Parquet → gold Delta tables.
3. **Redshift DW** — `NT_Accelerate_RedshiftDW_Master_Job` (`ID=3`).
   bronze Parquet → Redshift `tickit`.

Starting LakeHouse or RedshiftDW with `RUN_TYPE=NEW` before the Staging master job
has succeeded for the run date fails fast at the `Staging master job not running
yet` state.

### Starting a master job

Console: Step Functions → select the state machine → **Start execution** (empty
JSON `{}` input is fine).

CLI:

```bash
aws stepfunctions start-execution \
  --state-machine-arn <state machine ARN> \
  --region us-east-1
```

## Verification

After `terraform apply`, run the three master jobs in order, then check:

- **Delta gold**: `s3://<bucket>/lake/gold/tickit/<table>/_delta_log/` exists for
  all six Delta tables (`DateDim`, `VenueDim`, `CategoryDim`, `UserDim`,
  `EventDim`, `SalesFact`).
- **Redshift**: the six tables (`dim_date`, `dim_venue`, `dim_category`,
  `dim_user`, `dim_event`, `fact_sales`) exist in the `tickit` database with the
  expected row counts.
- **Run records**: `NT_Accelerate_JOB_LOG` and `NT_Accelarate_JOB_STATUS` (note
  the intentional misspelling) show `SUCCEEDED` for all twelve Day 3 jobs, with
  no unresolved `FAILED` rows.

Quick control-plane smoke tests:

```bash
aws lambda invoke --function-name NT_Accelerate_Read_Run_Type \
  --payload '{"p_masterjob_id": 2}' --region us-east-1 out.json

aws lambda invoke --function-name NT_Accelerate_Is_Allow_Running \
  --payload '{"p_job_name": "jb_DW_Delta_Load_DateDim", "p_run_date": "2024-01-01", "p_run_type": "NEW"}' \
  --region us-east-1 out.json
```

## Teardown

```bash
terraform destroy
```

Deletes the Day 3 Glue jobs, the Redshift cluster (no final snapshot), the
Redshift connection/secret/SGs/subnet group, and the Day 3 seed rows. Day 1 and
Day 2 resources are left intact.

## Known risk: Delta jar ABI

The provided `delta-spark_2.13-4.1.0.jar` is a Scala 2.13 / Spark 4.x build,
while Glue 3.0 ships Spark 3.x / Scala 2.12. Confirm the ABI match — or
substitute a Glue-compatible Delta jar (and matching `glue_version`) — before
running the Delta jobs end to end, otherwise they fail at runtime with
`NoSuchMethodError` / `ClassNotFoundException`.
