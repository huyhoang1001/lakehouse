#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Load the Tickit schema + sample data into the local SQL Server container.
#
# Run once after `docker compose up -d`. Azure SQL Edge ships without sqlcmd,
# so seeding is driven from the host and needs `brew install sqlcmd`.
#
# Re-running is safe: batch_seed.py skips tables whose COUNT(*) already matches.
#
# Env overrides:
#   LOCAL_SQL_SERVER    (default: localhost,1433)
#   LOCAL_SQL_USER      (default: sa)
#   LOCAL_SQL_PASSWORD  (default: MyPass123!)
#   TICKIT_SQL          (default: instruction/day1/tickit_db 2/tickit_db/tickit_script.sql)
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

SERVER="${LOCAL_SQL_SERVER:-localhost,1433}"
USER="${LOCAL_SQL_USER:-sa}"
PASSWORD="${LOCAL_SQL_PASSWORD:-MyPass123!}"
SCRIPT="${TICKIT_SQL:-$REPO_ROOT/instruction/day1/tickit_db 2/tickit_db/tickit_script.sql}"

if ! command -v sqlcmd >/dev/null 2>&1; then
  echo "ERROR: sqlcmd not found. Install with: brew install sqlcmd" >&2
  exit 1
fi

# -N disable: Azure SQL Edge's self-signed certificate has a negative serial
# number that Go's TLS stack rejects while parsing, so encryption is turned off.
echo "Waiting for SQL Server at ${SERVER} ..."
for _ in $(seq 1 60); do
  if sqlcmd -S "$SERVER" -U "$USER" -P "$PASSWORD" -N disable -Q "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "Ensuring database [tickit] exists ..."
sqlcmd -S "$SERVER" -U "$USER" -P "$PASSWORD" -N disable \
  -Q "IF DB_ID('tickit') IS NULL CREATE DATABASE tickit;" >/dev/null

echo "Seeding [tickit] (this takes a few minutes) ..."
exec python3 "$REPO_ROOT/infra/scripts/batch_seed.py" \
  --server "$SERVER" \
  --user "$USER" \
  --password "$PASSWORD" \
  --script "$SCRIPT" \
  --no-encrypt
