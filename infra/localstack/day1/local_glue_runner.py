"""Local Glue dev shim for running Glue scripts outside the managed service.

Four adjustments are applied to the *runtime* so the shipped job scripts can
run unmodified:

1. ``glueparquet`` -> ``parquet``
   The real AWS Glue ``glueparquet`` writer only exists inside the managed Glue
   service; aws-glue-libs raises:

       java.lang.RuntimeException: glueparquet format not supported for
       developer environment

   in the open-source / local runtime. The ETL logic is unaffected -- only the
   proprietary optimized Parquet writer is unavailable. For local testing we
   substitute Spark's standard Parquet writer.

2. ``from_catalog`` -> direct JDBC read (only when LOCAL_CATALOG_JDBC is set)
   The Glue Data Catalog is unavailable locally (LocalStack does not emulate
   Glue on the free tier, and there is no crawler). The full-load jobs read via
   ``glueContext.create_dynamic_frame.from_catalog(database, table_name)``,
   where the crawler names tables ``<db>_<schema>_<table>`` (e.g.
   ``tickit_dbo_venue``). When LOCAL_CATALOG_JDBC is set, that call is
   redirected to a direct Spark JDBC read of the local SQL Server, keeping the
   job scripts untouched.

   Env:
     LOCAL_CATALOG_JDBC      jdbc:sqlserver://host:1433;databaseName=tickit;...
     LOCAL_CATALOG_USER      login
     LOCAL_CATALOG_PASSWORD  password

3. ``from_jdbc_conf`` -> direct JDBC write (only when LOCAL_REDSHIFT_JDBC is set)
   The Day 3 warehouse jobs load through the Glue Data Catalog *connection*
   ``conRedshift_tickit``:
   ``glueContext.write_dynamic_frame.from_jdbc_conf(...)``. There is no catalog
   locally and LocalStack's free tier has no Redshift, so when
   LOCAL_REDSHIFT_JDBC is set that call is redirected to a plain Spark JDBC
   write against the local Postgres stand-in.

   This is an approximation, not a faithful Redshift test: the Redshift-only
   staging (``redshift_tmp_dir`` -- a COPY from S3) is not reproduced, the
   ``preactions`` (``drop table if exists <target>``) are covered by
   ``mode("overwrite")`` dropping the table, and the ``postactions``
   (``analyze <target>``) are cosmetic and skipped. The job scripts are left
   untouched.

   Env:
     LOCAL_REDSHIFT_JDBC      jdbc:postgresql://host:5432/tickit
     LOCAL_REDSHIFT_USER      postgres
     LOCAL_REDSHIFT_PASSWORD  password

4. ``spark.read.parquet(s3...)`` -> ``recursiveFileLookup=true``
   The Day 3 Delta jobs read the Day 1 bronze prefix, whose immediate children
   are directories (``lake/bronze/tickit/<table>/<run_date>/``). Against
   LocalStack S3, Spark's default leaf-file listing finds no files for such a
   prefix and schema inference fails with:

       Unable to infer schema for Parquet. It must be specified manually.

   Reading a directory that directly contains part-files works, so the failure
   depends only on the prefix's children being directories (not on naming, and
   not on S3A listing -- ``fs.s3a`` enumerates the leaf part-file correctly).
   Forcing ``recursiveFileLookup=true`` on every ``s3://`` Parquet read makes
   Spark descend into the date directories and infer the schema. The bronze
   data carries no partition columns (Day 1 writes ``partitionKeys: []``), so
   disabling partition discovery is harmless.

Usage (via run-glue.sh):
    spark-submit ... local_glue_runner.py <job_script.py> [--glue args...]
"""
import inspect
import os
import runpy
import sys

import awsglue.dynamicframe as _df

_orig_from_options = _df.DynamicFrameWriter.from_options
_sig = inspect.signature(_orig_from_options)


def _from_options(*args, **kwargs):
    bound = _sig.bind(*args, **kwargs)
    if str(bound.arguments.get("format", "")).lower() == "glueparquet":
        bound.arguments["format"] = "parquet"
        print("[local-glue] glueparquet -> parquet (local dev shim)")
    return _orig_from_options(*bound.args, **bound.kwargs)


_df.DynamicFrameWriter.from_options = _from_options


_LOCAL_JDBC = os.environ.get("LOCAL_CATALOG_JDBC")
if _LOCAL_JDBC:
    _Reader = _df.DynamicFrameReader
    _orig_from_catalog = _Reader.from_catalog

    def _parse_catalog_table(database, table_name):
        """tickit_dbo_venue -> ('dbo', 'venue'). None if it doesn't match."""
        rest = table_name or ""
        prefix = f"{database}_"
        if rest.startswith(prefix):
            rest = rest[len(prefix):]
        schema, sep, table = rest.partition("_")
        if not sep:
            return None
        return schema, table

    def _from_catalog(self, database=None, table_name=None, **kwargs):
        target = _parse_catalog_table(database, table_name)
        if not target:
            return _orig_from_catalog(
                self, database=database, table_name=table_name, **kwargs
            )
        schema, table = target
        glue_ctx = self._glue_context
        print(
            f"[local-glue] from_catalog {database}.{table_name} "
            f"-> JDBC [{schema}].[{table}]"
        )
        df = (
            glue_ctx.spark_session.read.format("jdbc")
            .option("url", _LOCAL_JDBC)
            .option("dbtable", f"[{schema}].[{table}]")
            .option("user", os.environ["LOCAL_CATALOG_USER"])
            .option("password", os.environ["LOCAL_CATALOG_PASSWORD"])
            .option("driver", "com.microsoft.sqlserver.jdbc.SQLServerDriver")
            .load()
        )
        return _df.DynamicFrame.fromDF(df, glue_ctx, table_name or table)

    _Reader.from_catalog = _from_catalog


_LOCAL_REDSHIFT = os.environ.get("LOCAL_REDSHIFT_JDBC")
if _LOCAL_REDSHIFT:
    _Writer = _df.DynamicFrameWriter
    _orig_from_jdbc_conf = _Writer.from_jdbc_conf

    def _from_jdbc_conf(
        self,
        frame,
        catalog_connection=None,
        connection_options=None,
        transformation_ctx="",
        **kwargs,
    ):
        options = connection_options or {}
        table = options.get("dbtable")
        if not table:
            # Nothing to redirect to; let the real code raise its usual error.
            return _orig_from_jdbc_conf(
                self, frame, catalog_connection, options, transformation_ctx, **kwargs
            )
        print(
            "[local-glue] from_jdbc_conf {} -> JDBC [{}] on {}".format(
                catalog_connection, table, _LOCAL_REDSHIFT
            )
        )
        if options.get("preactions"):
            print(
                "[local-glue] preactions covered by overwrite: {}".format(
                    options["preactions"]
                )
            )
        if options.get("postactions"):
            print(
                "[local-glue] postactions skipped locally: {}".format(
                    options["postactions"]
                )
            )
        # mode("overwrite") drops/creates the table, which is what the Redshift
        # preaction ("drop table if exists <target>") does, so the load is a
        # full replace exactly as the job intends.
        (
            frame.toDF()
            .write.format("jdbc")
            .option("url", _LOCAL_REDSHIFT)
            .option("dbtable", table)
            .option("user", os.environ["LOCAL_REDSHIFT_USER"])
            .option("password", os.environ["LOCAL_REDSHIFT_PASSWORD"])
            .option("driver", "org.postgresql.Driver")
            .mode("overwrite")
            .save()
        )
        return frame

    _Writer.from_jdbc_conf = _from_jdbc_conf


# LocalStack S3 + spark.read.parquet on a prefix of directories (see note 4).
import pyspark.sql.readwriter as _rw

_orig_parquet = _rw.DataFrameReader.parquet


def _parquet(self, *paths, **options):
    if any(str(p).startswith(("s3://", "s3a://")) for p in paths):
        options.setdefault("recursiveFileLookup", "true")
        print("[local-glue] parquet read: recursiveFileLookup=true (local dev shim)")
    return _orig_parquet(self, *paths, **options)


_rw.DataFrameReader.parquet = _parquet


target = sys.argv[1]
sys.argv = [target] + sys.argv[2:]
runpy.run_path(target, run_name="__main__")
