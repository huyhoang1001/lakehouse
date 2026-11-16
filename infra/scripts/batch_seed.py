#!/usr/bin/env python3
"""
batch_seed.py — seeds the tickit database, chunking large tables into
multiple sqlcmd sessions (5000 rows each) to avoid OOM on db.t3.micro.
Each session is independent so SQL Server can release memory between calls.
Supports resume: skips rows already inserted.

Usage:
  python3 batch_seed.py --server host,port --user u --password p --script path.sql
"""
import argparse, re, sys, subprocess, tempfile, os, time
from collections import OrderedDict

BATCH_SIZE   = 5      # rows per multi-value INSERT statement
SESSION_SIZE = 2000   # rows per sqlcmd invocation (memory boundary)

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--server",   required=True)
    p.add_argument("--user",     required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--script",   required=True)
    return p.parse_args()

def load_script(path):
    with open(path, "rb") as f:
        raw = f.read()
    return raw.decode("utf-16", errors="ignore")

def sqlcmd(server, user, password, sql, label=""):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write(sql); path = f.name
    r = subprocess.run(
        ["sqlcmd","-S",server,"-U",user,"-P",password,
         "-d","tickit","-i",path,"-t","600"],
        capture_output=True, text=True)
    os.unlink(path)
    errs = [l for l in (r.stdout+r.stderr).splitlines()
            if "Msg " in l and not any(x in l for x in ["2714","1781","1750"])]
    return errs

def count_rows(server, user, password, table):
    r = subprocess.run(
        ["sqlcmd","-S",server,"-U",user,"-P",password,"-d","tickit",
         "-Q",f"SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.[{table}];","-h","-1"],
        capture_output=True, text=True)
    try:
        return int(r.stdout.strip().splitlines()[0].strip())
    except:
        return 0

def seed_table(server, user, password, tbl, cols, rows, existing):
    total = len(rows)
    start = existing  # resume from where we left off
    if start >= total:
        print(f"  {tbl}: already complete ({existing:,}/{total:,})", flush=True)
        return True

    t0 = time.time()
    session_num = start // SESSION_SIZE
    pos = start
    while pos < total:
        end = min(pos + SESSION_SIZE, total)
        chunk = rows[pos:end]
        sql_lines = ["USE tickit;","GO"]
        for i in range(0, len(chunk), BATCH_SIZE):
            b = chunk[i:i+BATCH_SIZE]
            sql_lines.append(f"INSERT [dbo].[{tbl}] {cols} VALUES {','.join(b)};")
        sql_lines.append("GO")
        errs = sqlcmd(server, user, password, "\n".join(sql_lines), tbl)
        session_num += 1
        pct = int(end/total*100)
        print(f"  {tbl}: {end:,}/{total:,} ({pct}%) session={session_num} "
              f"[{time.time()-t0:.0f}s]" +
              (f" ERRORS: {errs[:1]}" if errs else ""), flush=True)
        if errs:
            return False
        pos = end

    return True

def main():
    args = parse_args()
    print("Loading script...", flush=True)
    text = load_script(args.script)
    lines = text.splitlines()

    insert_re = re.compile(
        r'^\s*INSERT \[dbo\]\.\[(\w+)\]\s*(\([^)]+\))\s*VALUES\s*(.+)', re.I)
    table_rows = OrderedDict()
    col_map = {}
    ddl_lines = []

    for line in lines:
        m = insert_re.match(line)
        if m:
            tbl, cols, vals = m.group(1), m.group(2), m.group(3).rstrip(";")
            if tbl not in col_map:
                col_map[tbl] = cols; table_rows[tbl] = []
            table_rows[tbl].append(vals)
        else:
            ddl_lines.append(line)

    print("Running DDL...", flush=True)
    sqlcmd(args.server, args.user, args.password, "\n".join(ddl_lines), "DDL")

    for tbl, rows in table_rows.items():
        existing = count_rows(args.server, args.user, args.password, tbl)
        seed_table(args.server, args.user, args.password,
                   tbl, col_map[tbl], rows, existing)

    print("\nFinal row counts:", flush=True)
    subprocess.run(["sqlcmd","-S",args.server,"-U",args.user,"-P",args.password,
        "-Q","""USE tickit;
SELECT 'category',COUNT(*) FROM dbo.category UNION ALL
SELECT 'date',COUNT(*) FROM dbo.[date] UNION ALL
SELECT 'event',COUNT(*) FROM dbo.event UNION ALL
SELECT 'listing',COUNT(*) FROM dbo.listing UNION ALL
SELECT 'sales',COUNT(*) FROM dbo.sales UNION ALL
SELECT 'users',COUNT(*) FROM dbo.users UNION ALL
SELECT 'venue',COUNT(*) FROM dbo.venue"""])

if __name__ == "__main__":
    main()
