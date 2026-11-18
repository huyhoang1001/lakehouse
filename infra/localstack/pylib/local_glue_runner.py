"""Local Glue dev shim for running Glue scripts outside the managed service.

Two adjustments are applied to the *runtime* so the shipped job scripts can run
unmodified:

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


target = sys.argv[1]
sys.argv = [target] + sys.argv[2:]
runpy.run_path(target, run_name="__main__")
