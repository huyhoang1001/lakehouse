#!/usr/bin/env python3
"""
batch_seed.py — load tickit into RDS SQL Server Express (db.t3.micro).

The source script is ~424k single-row INSERT statements. Replaying those
one statement at a time is parser-bound on a 1 GB instance and does not
reliably finish in 5 minutes. This script rewrites them as multi-row
INSERT ... VALUES (...), (...), ... and sends one sqlcmd process per table.

  - 200 rows per INSERT (SQL Server allows 1000; 200 stays small in memory)
  - COMMIT every 2000 rows, then GO (one network round trip per commit)
  - SET XACT_ABORT ON and sqlcmd -b so a statement error fails the load
  - Resume is all-or-nothing per table: heaps have no key, so a partial
    table is truncated and loaded again instead of skipped by COUNT(*)
  - After each table, COUNT(*) must match the script or the process exits 1

Usage:
  python3 batch_seed.py --server host,port --user u --password p --script path.sql
  python3 batch_seed.py --script path.sql --check
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict

ROWS_PER_INSERT = 200
ROWS_PER_COMMIT = 2000
# Benign on re-run: object already exists, column already has a DEFAULT,
# and the follow-on "could not create constraint" from that DEFAULT.
DDL_IGNORE = {"2714", "1781", "1750"}

INSERT_RE = re.compile(
    r"^\s*INSERT \[dbo\]\.\[(\w+)\]\s*(\([^)]+\))\s*VALUES\s*(.+)",
    re.IGNORECASE,
)


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--server", help="host,port")
    p.add_argument("--user")
    p.add_argument("--password")
    p.add_argument("--script", required=True)
    p.add_argument(
        "--check",
        action="store_true",
        help="parse the script and print row counts; do not connect",
    )
    args = p.parse_args()
    if not args.check and not (args.server and args.user and args.password):
        p.error("--server, --user, and --password are required unless --check")
    return args


def assert_not_lfs_pointer(path):
    with open(path, "rb") as f:
        header = f.read(80)
    if b"version https://git-lfs" in header:
        print("ERROR: tickit_script.sql is a Git LFS pointer, not the real file.")
        print(
            'Run:  git lfs pull --include="instruction/day1/tickit_db 2/tickit_db/tickit_script.sql"'
        )
        sys.exit(1)


def load_script(path):
    with open(path, "rb") as f:
        raw = f.read()
    # tickit_script.sql is UTF-16 LE with BOM
    return raw.decode("utf-16", errors="ignore")


def parse_script(text):
    table_rows = OrderedDict()
    col_map = {}
    ddl_lines = []
    insert_lines = 0
    for line in text.splitlines():
        if line.lstrip().upper().startswith("INSERT"):
            insert_lines += 1
        m = INSERT_RE.match(line)
        if m:
            tbl, cols, vals = m.group(1), m.group(2), m.group(3).rstrip().rstrip(";")
            if tbl not in col_map:
                col_map[tbl] = cols
                table_rows[tbl] = []
            table_rows[tbl].append(vals)
        else:
            ddl_lines.append(line)
    if insert_lines != sum(len(rows) for rows in table_rows.values()):
        raise SystemExit(
            f"ERROR: parsed {sum(len(rows) for rows in table_rows.values())} rows "
            f"from {insert_lines} INSERT lines. Refusing to load a partial parse."
        )
    return ddl_lines, table_rows, col_map


def build_table_sql(tbl, cols, rows):
    """Multi-row INSERTs, committed every ROWS_PER_COMMIT rows."""
    lines = ["SET NOCOUNT ON;", "SET XACT_ABORT ON;", "GO"]
    i = 0
    n = len(rows)
    while i < n:
        lines.append("BEGIN TRANSACTION;")
        end_tx = min(i + ROWS_PER_COMMIT, n)
        while i < end_tx:
            chunk = rows[i : i + ROWS_PER_INSERT]
            i += len(chunk)
            lines.append(
                f"INSERT [dbo].[{tbl}] {cols} VALUES\n" + ",\n".join(chunk) + ";"
            )
        lines.append("COMMIT TRANSACTION;")
        lines.append("GO")
    return "\n".join(lines)


def sql_errors(output, ignore):
    errs = []
    for line in output.splitlines():
        if "Msg " not in line:
            continue
        if any(code in line for code in ignore):
            continue
        errs.append(line)
    return errs


def run_sqlcmd(
    server, user, password, sql, db="tickit", input_path=None, ignore=(), abort=True
):
    cmd = [
        "sqlcmd",
        "-S",
        server,
        "-U",
        user,
        "-P",
        password,
        "-d",
        db,
        "-t",
        "0",
    ]
    # -b stops the file at the first error. DDL re-runs must keep going past
    # "object already exists"; data loads must stop.
    if abort:
        cmd.append("-b")
    if input_path:
        cmd.extend(["-i", input_path])
    else:
        cmd.extend(["-Q", sql])
    r = subprocess.run(cmd, capture_output=True, text=True)
    output = (r.stdout or "") + (r.stderr or "")
    errs = sql_errors(output, ignore)
    if abort and r.returncode != 0 and not errs:
        tail = output.strip().splitlines()
        errs = tail[-5:] or [f"sqlcmd exited {r.returncode}"]
    return errs


def count_rows(server, user, password, table):
    r = subprocess.run(
        [
            "sqlcmd",
            "-S",
            server,
            "-U",
            user,
            "-P",
            password,
            "-d",
            "tickit",
            "-b",
            "-h",
            "-1",
            "-W",
            "-Q",
            f"SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.[{table}];",
        ],
        capture_output=True,
        text=True,
    )
    output = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 or "Msg " in output:
        raise SystemExit(f"ERROR: could not count dbo.{table}:\n{output.strip()}")
    try:
        return int(output.strip().splitlines()[0].strip())
    except (IndexError, ValueError) as exc:
        raise SystemExit(
            f"ERROR: unexpected COUNT(*) output for dbo.{table}: {output!r}"
        ) from exc


def set_recovery(server, user, password, mode):
    errs = run_sqlcmd(
        server,
        user,
        password,
        f"ALTER DATABASE [tickit] SET RECOVERY {mode};",
        db="master",
    )
    if errs:
        print(f"  warning: could not set recovery {mode}: {errs[0]}", flush=True)
        return False
    print(f"  recovery model set to {mode}", flush=True)
    return True


def seed_table(server, user, password, tbl, cols, rows, existing):
    total = len(rows)
    if existing == total:
        print(f"  [{tbl}] already complete ({existing:,} rows)", flush=True)
        return True
    if existing > 0:
        print(
            f"  [{tbl}] count is {existing:,}, expected {total:,}; truncating and reloading",
            flush=True,
        )
        errs = run_sqlcmd(server, user, password, f"TRUNCATE TABLE dbo.[{tbl}];")
        if errs:
            print(f"  [{tbl}] truncate FAILED: {errs[:2]}", flush=True)
            return False
    else:
        print(f"  [{tbl}] seeding {total:,} rows...", flush=True)

    sql = build_table_sql(tbl, cols, rows)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".sql", delete=False, encoding="utf-8"
    ) as f:
        f.write(sql)
        path = f.name

    t0 = time.time()
    try:
        errs = run_sqlcmd(server, user, password, None, input_path=path)
    finally:
        os.unlink(path)
    elapsed = time.time() - t0

    if errs:
        print(f"  [{tbl}] FAILED ({elapsed:.0f}s): {errs[:3]}", flush=True)
        return False

    loaded = count_rows(server, user, password, tbl)
    if loaded != total:
        print(
            f"  [{tbl}] FAILED ({elapsed:.0f}s): count {loaded:,} != {total:,}",
            flush=True,
        )
        return False

    rps = int(total / elapsed) if elapsed > 0 else 0
    print(f"  [{tbl}] {total:,} rows in {elapsed:.0f}s ({rps:,} rows/s)", flush=True)
    return True


def main():
    args = parse_args()
    assert_not_lfs_pointer(args.script)

    print("Parsing script...", flush=True)
    t0 = time.time()
    text = load_script(args.script)
    ddl_lines, table_rows, col_map = parse_script(text)
    total_rows = sum(len(rows) for rows in table_rows.values())
    print(
        f"  {total_rows:,} rows across {len(table_rows)} tables "
        f"(parsed in {time.time() - t0:.1f}s)",
        flush=True,
    )
    for tbl, rows in table_rows.items():
        print(f"    {tbl}: {len(rows):,}", flush=True)

    if args.check:
        sample = next(iter(table_rows))
        sample_rows = table_rows[sample][: ROWS_PER_INSERT + 1]
        sql = build_table_sql(sample, col_map[sample], sample_rows)
        inserts = sql.count("INSERT ")
        print(
            f"  sample {sample}: {inserts} INSERT statement(s) "
            f"for {len(sample_rows)} rows"
        )
        return

    print("Setting recovery SIMPLE for the load...", flush=True)
    set_recovery(args.server, args.user, args.password, "SIMPLE")

    failed = False
    try:
        print("Creating tables (DDL)...", flush=True)
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".sql", delete=False, encoding="utf-8"
        ) as f:
            f.write("\n".join(ddl_lines))
            ddl_path = f.name
        try:
            errs = run_sqlcmd(
                args.server,
                args.user,
                args.password,
                None,
                input_path=ddl_path,
                ignore=DDL_IGNORE,
                abort=False,
            )
        finally:
            os.unlink(ddl_path)
        if errs:
            print(f"DDL FAILED: {errs[:5]}", flush=True)
            sys.exit(1)

        overall_t0 = time.time()
        for tbl, rows in table_rows.items():
            existing = count_rows(args.server, args.user, args.password, tbl)
            if not seed_table(
                args.server,
                args.user,
                args.password,
                tbl,
                col_map[tbl],
                rows,
                existing,
            ):
                failed = True
                break

        total_elapsed = time.time() - overall_t0
        print(
            f"\nSeed finished in {total_elapsed:.0f}s ({total_elapsed / 60:.1f} min)",
            flush=True,
        )
    finally:
        print("Restoring recovery FULL...", flush=True)
        set_recovery(args.server, args.user, args.password, "FULL")

    if failed:
        sys.exit(1)

    print("\nRow counts:", flush=True)
    subprocess.run(
        [
            "sqlcmd",
            "-S",
            args.server,
            "-U",
            args.user,
            "-P",
            args.password,
            "-b",
            "-Q",
            """USE tickit;
SELECT name, SUM(row_count) AS rows
FROM sys.dm_db_partition_stats p
JOIN sys.tables t ON t.object_id = p.object_id
WHERE index_id IN (0,1) AND SCHEMA_NAME(t.schema_id)='dbo'
GROUP BY name ORDER BY name""",
        ]
    )


if __name__ == "__main__":
    main()
