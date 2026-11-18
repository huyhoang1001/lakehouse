# Running the Lakehouse Locally for Free — LocalStack, Docker, and a Local SQL Server

*Companion guide to the 3-part lakehouse series — how to run the Day 1 pipeline entirely on your laptop without an AWS account.*

---

The [Day 1 ingestion post](./day1-ingestion.md) ends with a cost table and a warning: *"the main ongoing cost risk is forgetting to stop RDS."* That warning is real, but it hides a second problem that has nothing to do with money — **you cannot iterate quickly against a cloud stack you have to `terraform apply` and `terraform destroy` every time you change a line of a Glue script.**

So this guide is about a different trade: instead of paying a few cents per session for real AWS services, we stand up the *same* architecture on the laptop. The whole thing is **one `docker compose` file**, and the marginal cost of a run is **zero**.

| Piece | Cloud version | Local version | Local cost |
|-------|---------------|---------------|------------|
| Object storage | S3 | LocalStack S3 | $0 |
| Control plane | DynamoDB | LocalStack DynamoDB | $0 |
| Secrets | Secrets Manager | LocalStack Secrets Manager | $0 |
| Compute | AWS Glue (Spark) | Official Glue Docker image | $0 |
| Source DB | RDS SQL Server Express | Azure SQL Edge container | $0 |
| Catalog | AWS Glue Data Catalog | ⚠️ license-blocked → bridged to a direct JDBC read (see *Known gaps*) | $0 |

The local stack is completely independent of the cloud one: **it never runs Terraform**, and the files that make it work all live under [`infra/localstack/`](../infra/localstack/). Nothing you do locally changes what `terraform apply` does against real AWS — see [Keeping local and cloud separate](#keeping-local-and-cloud-separate).

---

## Quick start

Three commands from the repo root:

```bash
# 1. Get a free LocalStack auth token from https://app.localstack.cloud
cp infra/localstack/.env.example infra/localstack/.env
$EDITOR infra/localstack/.env          # paste LOCALSTACK_AUTH_TOKEN=...

# 2. Start LocalStack (S3/DynamoDB/Secrets Manager) + the local SQL Server
docker compose -f infra/localstack/docker-compose.yml up -d

# 3. Load the Tickit schema + data into the SQL container
#    (one time, ~1–2 min — the data is kept in a named volume, so later
#     `up`/`down` cycles reuse it)
infra/localstack/seed-sql.sh
```

That's the stack. Now run any Day 1 job:

```bash
infra/localstack/run-glue.sh jb_Stg_Extract_Venue.py \
  --JOB_NAME local-venue --p_job_name jb_Stg_Extract_Venue \
  --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
  --p_is_incremental_load False --p_catalog_conn conRDS_tickit \
  --p_src_databaseName tickit --p_src_tableName tickit_dbo_venue \
  --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
  --p_tar_tablename venue
```

When you are done:

```bash
docker compose -f infra/localstack/docker-compose.yml down
```

---

## Why local at all — and where it breaks

The honest starting point is that **LocalStack's free tier excludes exactly the two services this lab cares about most**. A healthy-looking instance will still fail at call time:

```bash
$ aws rds describe-db-instances
An error occurred (InternalFailure) when calling the DescribeDBInstances operation:
Sorry, the rds service is not included within your LocalStack license

$ aws glue get-databases
An error occurred (InternalFailure) when calling the GetDatabases operation:
Sorry, the glue service is not included within your LocalStack license
```

Two traps are worth knowing here. First, `/_localstack/health` still lists `rds` and `glue` as `"available"` — the health endpoint reflects whether the *service module loaded*, not whether your *license* permits invoking it. The real gate is at call time, and it returns `InternalFailure`, not `AccessDenied`; if you see `InternalFailure` on a service you just added, check the license before you check the IAM policy.

Second, every current LocalStack image — including the community `localstack/localstack` — **requires an auth token to start at all**, and quits with `License activation failed` without one. The token is free (Settings → Auth Token at [app.localstack.cloud](https://app.localstack.cloud)); it is what the `LOCALSTACK_AUTH_TOKEN` in `.env` is for.

That is the whole reason this guide exists: **Glue and RDS are the expensive parts, and LocalStack won't emulate them.** So we don't ask it to. LocalStack handles S3 + DynamoDB + Secrets Manager (all free); Glue runs as a real container; the database runs as a real container. Nothing is on the cloud, so nothing costs anything.

---

## The stack

### Services

[`infra/localstack/docker-compose.yml`](../infra/localstack/docker-compose.yml) defines three services on one network:

| Service | Image | What it is | Started by |
|---------|-------|------------|------------|
| `localstack` | `localstack/localstack` | S3, DynamoDB, Secrets Manager on `localhost:4566` | `up -d` |
| `sqlserver` | `mcr.microsoft.com/azure-sql-edge` | The source database on `localhost:1433` | `up -d` |
| `glue` | `public.ecr.aws/glue/aws-glue-libs:glue_libs_4.0.0_image_01` | The Glue/Spark runtime the jobs execute in | `run-glue.sh` (profile `tools`) |

Two design choices matter:

**The `glue` service is behind a profile.** A plain `docker compose up -d` starts only the two long-running services; the job container (a 9 GB image) is started on demand by `run-glue.sh`, which shells out to `docker compose run`. Because everything is on the same compose network, the job reaches LocalStack at `http://localstack:4566` and the database at `sqlserver:1433` **by service name** — no `host.docker.internal`, no host networking.

**The resources are created by an init hook, not by Terraform.** LocalStack runs every script in `/etc/localstack/init/ready.d/` once its API is up; [`init/01-provision.sh`](../infra/localstack/init/01-provision.sh) creates the S3 bucket and its objects, the four DynamoDB control tables and their seed rows, and the JDBC credentials secret. It is idempotent, so restarts are safe.

### Files

| File | Purpose |
|------|---------|
| `infra/localstack/docker-compose.yml` | The whole stack |
| `infra/localstack/.env.example` | Config template (copy to `.env`) |
| `infra/localstack/init/01-provision.sh` | LocalStack init hook — S3 + DynamoDB + Secrets Manager |
| `infra/localstack/seed-sql.sh` | Loads Tickit into the SQL container (host side) |
| `infra/localstack/run-glue.sh` | Runs a Glue job via `docker compose run` |
| `infra/localstack/pylib/sitecustomize.py` | Routes boto3 + rewrites the JDBC secret |
| `infra/localstack/pylib/local_glue_runner.py` | `glueparquet` → `parquet`, catalog → JDBC |

### Configuration

Everything is optional except the token. Compose reads `infra/localstack/.env` automatically:

| Variable | Default | Notes |
|----------|---------|-------|
| `LOCALSTACK_AUTH_TOKEN` | — | **Required.** Free token from app.localstack.cloud |
| `MSSQL_SA_PASSWORD` | `MyPass123!` | Password for the container's `sa` login (local throwaway) |
| `BUCKET_NAME` | `ntaccelerate-hoang-985176` | The bucket the jobs read/write |
| `AWS_DEFAULT_REGION` | `us-east-1` | Region the stack pretends to be in |

`.env` is gitignored; `.env.example` is committed. Everything else — image, mounts, endpoints, credentials — is wired in the compose file.

---

## Keeping local and cloud separate

The local path was deliberately built so that **no `.tf` or `.py` file changes behaviour under `terraform apply`**:

* **The local stack never runs Terraform.** The bucket, tables, and secret are created by the init hook, and Glue/RDS are replaced by containers. That is why this guide needs no `*_override.tf` files — there is nothing to create before a local run and nothing to remember to delete before a real one. (Earlier versions of this harness worked by *overriding* the Terraform config to point at LocalStack; those files are gone.)
* **The Glue scripts are unmodified.** All four differences between local and cloud are absorbed at runtime, by the two files under `infra/localstack/pylib/` (see below), which are mounted read-only into the job container only.
* **The one `.py` shared with the cloud path** is [`infra/scripts/batch_seed.py`](../infra/scripts/batch_seed.py), used by both `terraform apply` (against RDS) and `seed-sql.sh` (against the container). Its local-only behaviour is behind an opt-in `--no-encrypt` flag, so the default — and therefore the RDS path — is unchanged.

In short: `git diff` on the Terraform is what you deploy; `infra/localstack/` is a parallel way to run the same jobs.

---

## Running Glue locally

The trick is that AWS publishes the **actual Glue runtime** as a container image:

```
public.ecr.aws/glue/aws-glue-libs:glue_libs_4.0.0_image_01
```

Running our `jb_Stg_Extract_*.py` scripts inside it — unmodified — with `spark-submit` gives us the same Glue/Spark behaviour AWS uses, for free. A few small shims make the unmodified scripts work.

### Shim 1 — remap `s3://` to LocalStack's S3A endpoint

The image's Spark must believe `s3://` is served by LocalStack. [`run-glue.sh`](../infra/localstack/run-glue.sh) passes the S3A configuration on the `spark-submit` command line:

```
--conf spark.hadoop.fs.s3.impl=org.apache.hadoop.fs.s3a.S3AFileSystem
--conf spark.hadoop.fs.s3a.endpoint=http://localstack:4566
--conf spark.hadoop.fs.s3a.path.style.access=true
--conf spark.hadoop.fs.s3a.connection.ssl.enabled=false
--conf spark.hadoop.fs.s3a.access.key=test
--conf spark.hadoop.fs.s3a.secret.key=test
```

The endpoint is the compose service name, so the job container and LocalStack just talk to each other over the compose network.

### Shim 2 — old boto3 doesn't know `AWS_ENDPOINT_URL`

The Glue 4.0 image ships **boto3 1.24 / botocore 1.27**, which predate the `AWS_ENDPOINT_URL` environment variable. So the Glue scripts' boto3 calls would go to real AWS. [`sitecustomize.py`](../infra/localstack/pylib/sitecustomize.py) is auto-imported at interpreter start and monkey-patches `boto3.client` / `boto3.resource` to inject `endpoint_url` for the services the jobs use — **DynamoDB** (job log, watermark, status) and **Secrets Manager** (the JDBC credentials):

```python
_ROUTED = {"dynamodb", "secretsmanager"}

def _client(*args, **kwargs):
    service = args[0] if args else kwargs.get("service_name")
    if service in _ROUTED:
        kwargs.setdefault("endpoint_url", _endpoint)
        kwargs.setdefault("region_name", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    return _orig_client(*args, **kwargs)
```

The same shim also **rewrites the values inside the JDBC secret**, because the secret mirrors the *cloud* RDS instance while the job connects to the *local* container. Two things differ and both are fixed on the way out of `GetSecretValue`:

* **`db_url` host** — the stored URL points at `localhost:1433` (the host's view). From inside the job container that address is the container itself, so it is rewritten to `sqlserver`, and `encrypt=false;trustServerCertificate=true` is appended (the local SQL Server's self-signed certificate has a negative serial number the JDBC TLS layer rejects).
* **`db_username`** — the secret stores the RDS master user (`admin`), but the local container's master login is `sa`. Mapping the secret onto `sa` keeps the scripts unmodified and means no extra SQL login has to be provisioned locally.

Both rewrites are opt-in via `LOCAL_SECRET_JDBC_HOST` / `LOCAL_SECRET_JDBC_USER` (set in the compose file):

```python
def _rewrite_secret(response):
    secret = json.loads(response["SecretString"])
    if _secret_user:
        secret["db_username"] = _secret_user
    url = secret.get("db_url")
    if url and "jdbc:sqlserver://" in url:
        url = re.sub(r"//(localhost|127\.0\.0\.1)(:\d+)", rf"//{_secret_host}\2", url)
        if "encrypt=" not in url:
            url += ";encrypt=false;trustServerCertificate=true"
        secret["db_url"] = url
    response["SecretString"] = json.dumps(secret)
    return response
```

### Shim 3 — `glueparquet` doesn't exist outside managed Glue

The Glue scripts write with `format="glueparquet"`, a **proprietary writer that only exists inside the managed Glue service**. In the open-source/local runtime it raises:

```
java.lang.RuntimeException: glueparquet format not supported for developer environment
```

The ETL logic is unaffected — only the optimized writer is missing. Rather than edit the shipped scripts, [`local_glue_runner.py`](../infra/localstack/pylib/local_glue_runner.py) wraps `DynamicFrameWriter.from_options`, swaps `glueparquet` → Spark's standard `parquet`, and then `runpy`-executes the real script:

```python
def _from_options(*args, **kwargs):
    bound = _sig.bind(*args, **kwargs)
    if str(bound.arguments.get("format", "")).lower() == "glueparquet":
        bound.arguments["format"] = "parquet"
        print("[local-glue] glueparquet -> parquet (local dev shim)")
    return _orig_from_options(*bound.args, **bound.kwargs)
```

### Shim 4 — Glue Data Catalog → direct JDBC read

The six full-load jobs read their source through `glueContext.create_dynamic_frame.from_catalog(...)`, which needs the Glue Data Catalog — again **license-blocked**. [`local_glue_runner.py`](../infra/localstack/pylib/local_glue_runner.py) patches `DynamicFrameReader.from_catalog` so that a catalog reference like `tickit.tickit_dbo_venue` becomes a **direct Spark JDBC read** of the same table in the local SQL Server. The crawler names catalog tables `<db>_<schema>_<table>`, so the table name is parsed back into schema + table:

```python
def _parse_catalog_table(database, table_name):
    """tickit_dbo_venue -> ('dbo', 'venue')"""
    rest = table_name or ""
    prefix = f"{database}_"
    if rest.startswith(prefix):
        rest = rest[len(prefix):]
    schema, sep, table = rest.partition("_")
    return (schema, table) if sep else None

def _from_catalog(self, database=None, table_name=None, **kwargs):
    target = _parse_catalog_table(database, table_name)
    if not target:
        return _orig_from_catalog(self, database=database, table_name=table_name, **kwargs)
    schema, table = target
    glue_ctx = self._glue_context
    print(f"[local-glue] from_catalog {database}.{table_name} -> JDBC [{schema}].[{table}]")
    df = (glue_ctx.spark_session.read.format("jdbc")
          .option("url", _LOCAL_JDBC)
          .option("dbtable", f"[{schema}].[{table}]")
          .option("user", os.environ["LOCAL_CATALOG_USER"])
          .option("password", os.environ["LOCAL_CATALOG_PASSWORD"])
          .option("driver", "com.microsoft.sqlserver.jdbc.SQLServerDriver")
          .load())
    return _df.DynamicFrame.fromDF(df, glue_ctx, table_name or table)
```

The JDBC connection comes from `LOCAL_CATALOG_JDBC` / `LOCAL_CATALOG_USER` / `LOCAL_CATALOG_PASSWORD` (set in the compose file). With this bridge in place, **every** Day 1 job — the six full-load jobs and the incremental Sales job — runs end-to-end locally against S3 + DynamoDB + the SQL Server container.

### Running a job

`run-glue.sh` mounts the Glue scripts, the shared `library/`, the `raw/` landing zone, and `pylib/` read-only into the container, runs a **login shell** (so `.bashrc` sets `SPARK_HOME`, `PYTHONPATH`, and `PyGlue.zip`, which `import awsglue` needs), pip-installs the extras the flat-file job needs (`openpyxl==3.0.10`), and finally invokes `spark-submit`:

```bash
# the flat-file job (reads a file from the raw/ landing zone)
infra/localstack/run-glue.sh jb_Stg_Extract_ExcelFile.py \
  --JOB_NAME local-excel --p_job_name jb_Stg_Extract_ExcelFile \
  --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
  --p_src_databaseName /home/glue_user/workspace/raw/excel/ \
  --p_src_tableName SalesEvent.xlsx \
  --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
  --p_tar_tablename salesevent

# a full-load job (reads via the catalog -> JDBC bridge)
infra/localstack/run-glue.sh jb_Stg_Extract_Venue.py \
  --JOB_NAME local-venue --p_job_name jb_Stg_Extract_Venue \
  --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
  --p_is_incremental_load False --p_catalog_conn conRDS_tickit \
  --p_src_databaseName tickit --p_src_tableName tickit_dbo_venue \
  --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
  --p_tar_tablename venue

# the incremental job (credentials from Secrets Manager + watermark)
infra/localstack/run-glue.sh jb_Stg_Extract_Sales.py \
  --JOB_NAME local-sales --p_job_name jb_Stg_Extract_Sales \
  --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
  --p_is_incremental_load True --p_catalog_conn conRDS_tickit \
  --p_src_databaseName tickit --p_src_tableName tickit_dbo_sales \
  --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
  --p_tar_tablename sales
```

If the stack isn't running yet, `docker compose run` starts it first and waits for both dependencies to report healthy.

---

## The local SQL Server

### Choosing an image

There are two candidates and only one of them is pleasant on an Apple Silicon laptop:

| Image | Architecture | Verdict |
|-------|--------------|---------|
| `mcr.microsoft.com/mssql/server` | amd64 only | Runs under emulation on arm64 — slow, memory-hungry |
| `mcr.microsoft.com/azure-sql-edge` | **native arm64** | T-SQL / SQL-Server compatible, free, fast |

**Azure SQL Edge is the right choice on arm64.** It's a SQL-Server-compatible engine built for edge devices, and (unlike the full `mssql` image) it ships an arm64 build, so it runs natively on Apple Silicon without emulation.

### Why seeding runs from the host

Azure SQL Edge ships **no client tools** — no `sqlcmd`, so nothing inside the container can run the seed script. Instead, `seed-sql.sh` drives the load from your machine (it needs `brew install sqlcmd`) and points at the published `localhost:1433`:

```bash
infra/localstack/seed-sql.sh
```

Under the hood it creates the database, then hands the script to [`infra/scripts/batch_seed.py`](../infra/scripts/batch_seed.py):

```bash
sqlcmd -S localhost,1433 -U sa -P 'MyPass123!' -N disable \
  -Q "IF DB_ID('tickit') IS NULL CREATE DATABASE tickit;"

python3 infra/scripts/batch_seed.py \
  --server localhost,1433 --user sa --password 'MyPass123!' --no-encrypt \
  --script "instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"
```

`batch_seed.py` exists because the seed file is 235 MB of *single-row* INSERTs (~424k statements), which is parser-bound and never finishes in reasonable time. It rewrites them into multi-row batches — 200 rows per `INSERT`, a `COMMIT` every 2000 rows, `SET XACT_ABORT ON`, and a per-table `COUNT(*)` check — with all-or-nothing resume per table (heaps have no key, so a partial table is truncated and reloaded rather than skipped). Re-running `seed-sql.sh` is safe: already-complete tables are skipped.

### The certificate trap: `x509: negative serial number`

Connect with the modern Go-based `sqlcmd` without `-N disable` and you hit this:

```
TLS Handshake failed: tls: failed to parse certificate from server: x509: negative serial number
```

Azure SQL Edge presents a **self-signed certificate with a negative serial number**, which the Go TLS stack rejects *while parsing the certificate*, before any trust decision is made. That is why the usual `-C` / `--trust-server-certificate` flag does **not** help: trusting the certificate comes *after* the handshake, and the handshake never completes. Turning encryption off is the fix for a purely local connection — which is why `seed-sql.sh` and `batch_seed.py` pass `-N disable` / `--no-encrypt`.

The flag is **opt-in** precisely so the real-AWS seed path is untouched: real RDS may require encryption, and the default behaviour stays exactly as it was.

A run looks like this:

```
Parsing script...
  424,172 rows across 7 tables (parsed in 0.5s)
Setting recovery SIMPLE for the load...
Creating tables (DDL)...
  [category] seeding 11 rows...
  [date] seeding 365 rows...
  [event] seeding 8,659 rows...
  [listing] seeding 192,497 rows...
  [sales] seeding 172,448 rows...
  [users] seeding 49,990 rows...
  [venue] seeding 202 rows...
Seed finished in 69s (1.2 min)
```

Verified counts after the load:

| Table | Rows |
|-------|------|
| `category` | 11 |
| `date` | 365 |
| `event` | 8,659 |
| `listing` | 192,497 |
| `sales` | 172,448 |
| `users` | 49,990 |
| `venue` | 202 |
| **Total** | **424,172** |

---

## Verifying the whole stack

```bash
# LocalStack is up and the init hook provisioned everything
docker exec nt-localstack aws --endpoint-url http://localhost:4566 s3 ls s3://ntaccelerate-hoang-985176/
docker exec nt-localstack aws --endpoint-url http://localhost:4566 dynamodb list-tables

# The source database is seeded
sqlcmd -S localhost,1433 -U sa -P 'MyPass123!' -N disable \
  -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM tickit.dbo.sales;"

# Run a full-load job and the incremental job
infra/localstack/run-glue.sh jb_Stg_Extract_Venue.py \
  --JOB_NAME local-venue --p_job_name jb_Stg_Extract_Venue \
  --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
  --p_is_incremental_load False --p_catalog_conn conRDS_tickit \
  --p_src_databaseName tickit --p_src_tableName tickit_dbo_venue \
  --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
  --p_tar_tablename venue

infra/localstack/run-glue.sh jb_Stg_Extract_Sales.py \
  --JOB_NAME local-sales --p_job_name jb_Stg_Extract_Sales \
  --p_run_date 2026-11-18 --p_batch_id 1 --p_region us-east-1 \
  --p_is_incremental_load True --p_catalog_conn conRDS_tickit \
  --p_src_databaseName tickit --p_src_tableName tickit_dbo_sales \
  --p_tar_databaseName s3://ntaccelerate-hoang-985176/lake/bronze/tickit/ \
  --p_tar_tablename sales

# What the job recorded (source/target counts, status) ...
docker exec nt-localstack aws --endpoint-url http://localhost:4566 dynamodb scan \
  --table-name NT_Accelerate_JOB_LOG

# ... and where the parquet landed
docker exec nt-localstack aws --endpoint-url http://localhost:4566 s3 ls --recursive \
  s3://ntaccelerate-hoang-985176/lake/bronze/tickit/
```

On the machine this guide was written on, all seven SQL-backed jobs plus the Excel job land under `lake/bronze/tickit/<table>/<run_date>/`.

One thing to know about the incremental Sales job: the stack seeds its watermark (`NT_Acccelarate_WATERMARKTABLE`, gate `saletime`) to the **source maximum** `2008-12-31 12:58:19` — the same value Terraform seeds against real RDS. So the *first* incremental run reports `SOURCE_COUNT = TARGET_COUNT = 0`: there is nothing newer than the mark. To watch rows actually flow, lower the watermark and run again — the job then reports `SOURCE_COUNT = TARGET_COUNT = 18` and advances the mark back to `2008-12-31 12:58:19`:

```bash
# Rewind the Sales watermark to midnight, then re-run the job above
docker exec nt-localstack aws --endpoint-url http://localhost:4566 dynamodb update-item \
  --table-name NT_Acccelarate_WATERMARKTABLE \
  --key '{"ID":{"N":"0"},"JOB_NAME":{"S":"jb_Stg_Extract_Sales"}}' \
  --update-expression 'SET DATA_VALUES = :v' \
  --expression-attribute-values '{":v":{"L":[{"S":"2008-12-31 00:00:00"}]}}'
```

---

## Known gaps

The local stack is deliberately *not* a full emulator. Two differences are worth remembering:

**The Glue Data Catalog is license-blocked — bridged, not emulated.** The six full-load jobs read via `create_dynamic_frame.from_catalog`, which needs the catalog LocalStack refuses. Shim 4 in [`local_glue_runner.py`](../infra/localstack/pylib/local_glue_runner.py) maps the catalog reference `tickit.tickit_dbo_<table>` to a **direct JDBC read** from the local SQL Server container, keeping the shipped job scripts unmodified. This is a *behavioural substitute*, not a crawler: it assumes the table naming the crawler would have produced and does not exercise schema inference or catalog updates. Everything downstream of the read (transforms, the `glueparquet`/DynamoDB job-logging path, the watermark) runs for real.

**The JDBC credentials are local, so the secret is rewritten in flight.** The Secrets Manager secret mirrors the cloud RDS instance (`admin` @ `localhost:1433`), while the job talks to the local container (`sa` @ `sqlserver:1433`); Shim 2 rewrites both on the way out. That means the incremental path is exercised end-to-end, but the local run does not prove that the cloud secret and the cloud RDS master user agree — apply to real RDS to check that.

---

## Cost

| | Cloud session | Local session |
|---|---|---|
| RDS `db.t3.micro` (~2 hr) | ~$0.03 | $0 |
| Glue crawler (~5 min) | ~$0.17 | $0 |
| 7 Glue jobs (~5 min each) | ~$0.50 | $0 |
| S3 + DynamoDB + Secrets Manager | ~$0.02 | $0 |
| **Total** | **~$0.75 / session** | **$0** |

The cloud number is small, which is exactly why people are tempted to skip local development. But the cloud number repeats every time you change a script, and the *latency* cost — `terraform apply`, wait for an instance, wait for a job to start — is what actually slows you down. Local is $0 and instant.

---

## Teardown

```bash
docker compose -f infra/localstack/docker-compose.yml down
```

The job container uses `--rm`, so it discards itself after each run. `down` removes both long-running containers and the network. **LocalStack keeps no state between runs** — the next `up` starts from a clean slate and the init hook provisions the S3 bucket, tables, and secret again. **The SQL Server's Tickit data does persist**, because it lives in the named volume `sqlserver-data`; that is what makes `seed-sql.sh` a one-time step. To wipe the database too:

```bash
docker compose -f infra/localstack/docker-compose.yml down -v
```

---

*This guide documents the local harness behind the [Day 1 ingestion post](./day1-ingestion.md). The harness lives in [`infra/localstack/`](../infra/localstack/), with the shared seeding helper in [`infra/scripts/batch_seed.py`](../infra/scripts/batch_seed.py).*
