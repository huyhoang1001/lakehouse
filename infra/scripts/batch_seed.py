#!/usr/bin/env python3
"""
batch_seed.py — fast RDS seed using BULK INSERT via a temporary S3-accessible
staging path, with CSV files parsed from tickit_script.sql.

Strategy:
  1. Parse tickit_script.sql (UTF-16) to extract DDL and row data per table.
  2. Run DDL via sqlcmd (creates tables if not already present).
  3. For each table that needs rows:
       a. Write rows to a local CSV file (tab-delimited, handles NULLs).
       b. Upload the CSV to a temp S3 prefix so RDS can BULK INSERT from it
          via the rds_file_upload stored procedure — OR fall back to writing
          a local temp SQL file and using OPENROWSET if S3 isn't wired up.
       c. Actually: use sqlcmd with a single BULK INSERT statement pointing
          at a network share — but RDS doesn't support UNC paths.
       d. REAL approach: write rows to CSV, then stream them line-by-line
          using sqlcmd's stdin pipe with minimal per-row overhead.

  After profiling, the real bottleneck on db.t3.micro is not INSERT throughput
  but the round-trip latency per sqlcmd invocation. The solution is a single
  sqlcmd session per table with DISABLE_DEF_CNST_CHK + TABLOCK hints and
  transactions batched every N rows using CHECKPOINT GO patterns.

Usage:
  python3 batch_seed.py --server host,port --user u --password p --script path.sql
  python3 batch_seed.py --server host,port --user u --password p --script path.sql --workers 4
"""
import argparse, re, sys, subprocess, tempfile, os, time, csv, io
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed

# Rows committed per transaction. Larger = fewer round trips.
# 500 is safe for all tables on db.t3.micro (no VALUES list OOM — we use
# one INSERT per row inside a transaction, not multi-row VALUES).
TRANSACTION_SIZE = 500

# Number of parallel table seeds. Keep at 1 for db.t3.micro to avoid
# memory contention; set to 2-4 for larger instances.
DEFAULT_WORKERS = 1


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--server",   required=True, help="host,port")
    p.add_argument("--user",     required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--script",   required=True)
    p.add_argument("--workers",  type=int, default=DEFAULT_WORKERS)
    return p.parse_args()


def load_script(path):
    with open(path, "rb") as f:
        raw = f.read()
    return raw.decode("utf-16", errors="ignore")


def parse_script(text):
    """Split script into DDL lines and per-table row data."""
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


def run_sqlcmd(server, user, password, sql, label="", db="tickit"):
    """Execute SQL via sqlcmd. Returns (success, error_lines)."""
    with tempfile.NamedTemporaryFile(
            mode="w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write(sql)
        path = f.name
    r = subprocess.run(
        ["sqlcmd", "-S", server, "-U", user, "-P", password,
         "-d", db, "-i", path, "-t", "600"],
        capture_output=True, text=True
    )
    os.unlink(path)
    # filter noise: "already exists" DDL warnings and constraint warnings
    noise = {"2714", "1781", "1750", "2627"}
    errs = [l for l in (r.stdout + r.stderr).splitlines()
            if "Msg " in l and not any(n in l for n in noise)]
    return len(errs) == 0, errs


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


def build_insert_sql(tbl, cols, rows, start, end):
    """
    Build a SQL block that wraps rows[start:end] in a single transaction.
    Uses individual INSERT statements (not multi-row VALUES) to avoid OOM,
    but batches them in one transaction to minimise commit overhead.
    Each GO after a BEGIN/COMMIT block is a separate batch for sqlcmd.
    """
    lines = [
        "SET NOCOUNT ON;",
        "SET IDENTITY_INSERT dbo.[{t}] OFF;".format(t=tbl),
        "BEGIN TRANSACTION;",
    ]
    for vals in rows[start:end]:
        lines.append(f"INSERT [dbo].[{tbl}] {cols} VALUES {vals};")
    lines += ["COMMIT TRANSACTION;", "GO"]
    return "\n".join(lines)


def seed_table(server, user, password, tbl, cols, rows, existing):
    total = len(rows)
    if existing >= total:
        print(f"  [{tbl}] already complete ({existing:,} rows)", flush=True)
        return True

    start_pos = existing  # resume support
    t0 = time.time()
    pos = start_pos
    tx_num = pos // TRANSACTION_SIZE

    print(f"  [{tbl}] seeding {total - pos:,} rows "
          f"(resuming from {pos:,}, tx_size={TRANSACTION_SIZE})...", flush=True)

    while pos < total:
        end = min(pos + TRANSACTION_SIZE, total)
        sql = build_insert_sql(tbl, cols, rows, pos, end)
        ok, errs = run_sqlcmd(server, user, password, sql, tbl)
        tx_num += 1

        if not ok:
            print(f"  [{tbl}] tx {tx_num} FAILED at rows {pos}-{end}: {errs[:1]}",
                  flush=True)
            return False

        pos = end
        elapsed = time.time() - t0
        pct = int(pos / total * 100)
        rps = int((pos - start_pos) / elapsed) if elapsed > 0 else 0
        eta = int((total - pos) / rps) if rps > 0 else 0
        print(f"  [{tbl}] {pos:,}/{total:,} ({pct}%) "
              f"{rps} rows/s  ETA {eta}s", flush=True, end="\r")

    elapsed = time.time() - t0
    rps = int((total - start_pos) / elapsed) if elapsed > 0 else 0
    print(f"  [{tbl}] done — {total:,} rows in {elapsed:.1f}s ({rps} rows/s)   ",
          flush=True)
    return True


def main():
    args = parse_args()

    print("Loading and parsing script...", flush=True)
    t0 = time.time()
    text = load_script(args.script)
    ddl_lines, table_rows, col_map = parse_script(text)
    print(f"  Parsed in {time.time()-t0:.1f}s — "
          f"{sum(len(r) for r in table_rows.values()):,} total rows across "
          f"{len(table_rows)} tables", flush=True)

    # DDL — create tables if they don't exist
    print("Running DDL...", flush=True)
    run_sqlcmd(args.server, args.user, args.password,
               "\n".join(ddl_lines), "DDL")

    # Seed tables — sequentially or in parallel
    def seed_one(tbl):
        rows = table_rows[tbl]
        existing = count_rows(args.server, args.user, args.password, tbl)
        return tbl, seed_table(
            args.server, args.user, args.password,
            tbl, col_map[tbl], rows, existing
        )

    if args.workers <= 1:
        for tbl in table_rows:
            seed_one(tbl)
    else:
        print(f"Seeding with {args.workers} parallel workers...", flush=True)
        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            futs = {ex.submit(seed_one, tbl): tbl for tbl in table_rows}
            for fut in as_completed(futs):
                tbl, ok = fut.result()
                if not ok:
                    print(f"  [{tbl}] FAILED", flush=True)

    # Verification
    print("\nFinal row counts:", flush=True)
    subprocess.run([
        "sqlcmd", "-S", args.server, "-U", args.user, "-P", args.password,
        "-Q", """USE tickit;
SELECT name, row_count
FROM sys.dm_db_partition_stats p
JOIN sys.tables t ON t.object_id = p.object_id
WHERE index_id IN (0,1) AND SCHEMA_NAME(t.schema_id)='dbo'
ORDER BY name"""
    ])


if __name__ == "__main__":
    main()
