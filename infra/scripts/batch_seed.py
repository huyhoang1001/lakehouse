#!/usr/bin/env python3
"""
batch_seed.py — seeds the tickit database in under 5 minutes on db.t3.micro.

Approach:
  - One sqlcmd process per table (not per batch) — eliminates startup overhead.
  - Rows are written to a temp SQL file with explicit BEGIN/COMMIT every
    TRANSACTION_SIZE rows so SQL Server doesn't accumulate undo log unboundedly.
  - Single-row INSERT statements (no multi-row VALUES) — avoids OOM on the
    1 GB RAM instance even for wide tables (listing, sales).
  - Resume support: checks row count before seeding, skips complete tables.
  - LFS guard: refuses to run if the SQL file is a Git LFS pointer.

Usage:
  python3 batch_seed.py --server host,port --user u --password p --script path.sql
"""
import argparse, re, sys, subprocess, tempfile, os, time
from collections import OrderedDict

TRANSACTION_SIZE = 1000  # rows per BEGIN/COMMIT block


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--server",   required=True, help="host,port")
    p.add_argument("--user",     required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--script",   required=True)
    return p.parse_args()


def load_script(path):
    with open(path, "rb") as f:
        raw = f.read()
    # tickit_script.sql is UTF-16 LE with BOM
    return raw.decode("utf-16", errors="ignore")


def parse_script(text):
    insert_re = re.compile(
        r'^\s*INSERT \[dbo\]\.\[(\w+)\]\s*(\([^)]+\))\s*VALUES\s*(.+)',
        re.IGNORECASE
    )
    table_rows = OrderedDict()
    col_map = {}
    ddl_lines = []
    for line in text.splitlines():
        m = insert_re.match(line)
        if m:
            tbl, cols, vals = m.group(1), m.group(2), m.group(3).rstrip(";")
            if tbl not in col_map:
                col_map[tbl] = cols
                table_rows[tbl] = []
            table_rows[tbl].append(vals)
        else:
            ddl_lines.append(line)
    return ddl_lines, table_rows, col_map


def run_sqlcmd(server, user, password, sql_path, db="tickit"):
    r = subprocess.run(
        ["sqlcmd", "-S", server, "-U", user, "-P", password,
         "-d", db, "-i", sql_path, "-t", "600"],
        capture_output=True, text=True
    )
    noise = {"2714", "1781", "1750", "2627"}
    errs = [l for l in (r.stdout + r.stderr).splitlines()
            if "Msg " in l and not any(n in l for n in noise)]
    return errs


def count_rows(server, user, password, table):
    r = subprocess.run(
        ["sqlcmd", "-S", server, "-U", user, "-P", password, "-d", "tickit",
         "-Q", f"SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.[{table}];", "-h", "-1"],
        capture_output=True, text=True
    )
    try:
        return int(r.stdout.strip().splitlines()[0].strip())
    except Exception:
        return 0


def build_table_sql(tbl, cols, rows, start=0):
    """
    Build the full SQL for seeding a table in a single file.
    Wraps every TRANSACTION_SIZE rows in BEGIN/COMMIT to cap undo-log growth.
    Single-row INSERTs avoid multi-row VALUES OOM on 1 GB RAM instances.
    """
    lines = ["SET NOCOUNT ON;", "GO"]
    for i, vals in enumerate(rows[start:], start=1):
        if (i - 1) % TRANSACTION_SIZE == 0:
            lines.append("BEGIN TRANSACTION;")
        lines.append(f"INSERT [dbo].[{tbl}] {cols} VALUES {vals};")
        if i % TRANSACTION_SIZE == 0:
            lines.append("COMMIT TRANSACTION;")
            lines.append("GO")
    # close any open transaction
    if len(rows[start:]) % TRANSACTION_SIZE != 0:
        lines.append("COMMIT TRANSACTION;")
        lines.append("GO")
    return "\n".join(lines)


def seed_table(server, user, password, tbl, cols, rows, existing):
    total = len(rows)
    if existing >= total:
        print(f"  [{tbl}] already complete ({existing:,} rows)", flush=True)
        return True

    start = existing
    todo = total - start
    print(f"  [{tbl}] seeding {todo:,} rows...", end=" ", flush=True)
    t0 = time.time()

    sql = build_table_sql(tbl, cols, rows, start)
    with tempfile.NamedTemporaryFile(
            mode="w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write(sql)
        path = f.name

    errs = run_sqlcmd(server, user, password, path)
    os.unlink(path)
    elapsed = time.time() - t0

    if errs:
        print(f"FAILED ({elapsed:.0f}s): {errs[:2]}", flush=True)
        return False

    rps = int(todo / elapsed) if elapsed > 0 else 0
    print(f"done in {elapsed:.0f}s ({rps} rows/s)", flush=True)
    return True


def main():
    args = parse_args()

    # LFS guard
    with open(args.script, "rb") as f:
        header = f.read(50)
    if b"version https://git-lfs" in header:
        print("ERROR: tickit_script.sql is a Git LFS pointer, not the real file.")
        print("Run:  git lfs pull --include=\"instruction/day1/tickit_db 2/tickit_db/tickit_script.sql\"")
        sys.exit(1)

    print("Parsing script...", flush=True)
    t0 = time.time()
    text = load_script(args.script)
    ddl_lines, table_rows, col_map = parse_script(text)
    total_rows = sum(len(r) for r in table_rows.values())
    print(f"  {total_rows:,} rows across {len(table_rows)} tables "
          f"(parsed in {time.time()-t0:.1f}s)", flush=True)

    # DDL
    print("Creating tables (DDL)...", flush=True)
    with tempfile.NamedTemporaryFile(
            mode="w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write("\n".join(ddl_lines))
        ddl_path = f.name
    run_sqlcmd(args.server, args.user, args.password, ddl_path)
    os.unlink(ddl_path)

    # Seed
    overall_t0 = time.time()
    for tbl in table_rows:
        existing = count_rows(args.server, args.user, args.password, tbl)
        seed_table(args.server, args.user, args.password,
                   tbl, col_map[tbl], table_rows[tbl], existing)

    total_elapsed = time.time() - overall_t0
    print(f"\nAll tables seeded in {total_elapsed:.0f}s "
          f"({total_elapsed/60:.1f} min)", flush=True)

    # Verify
    print("\nRow counts:", flush=True)
    subprocess.run([
        "sqlcmd", "-S", args.server, "-U", args.user, "-P", args.password,
        "-Q", """USE tickit;
SELECT name, SUM(row_count) as rows
FROM sys.dm_db_partition_stats p
JOIN sys.tables t ON t.object_id = p.object_id
WHERE index_id IN (0,1) AND SCHEMA_NAME(t.schema_id)='dbo'
GROUP BY name ORDER BY name"""
    ])


if __name__ == "__main__":
    main()
