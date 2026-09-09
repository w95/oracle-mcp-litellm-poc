#!/bin/bash
# ---------------------------------------------------------------------
# One-shot schema + data loader for the BIR PoC.
# Runs inside the Oracle image (which ships sqlplus) as a separate
# compose service, once the database container reports healthy.
# Idempotent: exits early if BIR.ACCOUNTS already holds rows.
# ---------------------------------------------------------------------
set -euo pipefail

DB_HOST="${DB_HOST:-oracle}"
DB_PORT="${DB_PORT:-1521}"
DB_SERVICE="${DB_SERVICE:-FREEPDB1}"
ORACLE_PWD="${ORACLE_PWD:?ORACLE_PWD must be set}"
BIR_PWD="${BIR_PWD:?BIR_PWD must be set}"
BIR_RO_PWD="${BIR_RO_PWD:?BIR_RO_PWD must be set}"

CONN="sys/${ORACLE_PWD}@//${DB_HOST}:${DB_PORT}/${DB_SERVICE} as sysdba"

echo "[init] waiting for ${DB_HOST}:${DB_PORT}/${DB_SERVICE} ..."
for i in $(seq 1 120); do
  if echo "SELECT 1 FROM dual;" | sqlplus -s -L "$CONN" >/dev/null 2>&1; then
    echo "[init] database reachable after ${i} attempt(s)"
    break
  fi
  if [ "$i" = "120" ]; then
    echo "[init] ERROR: database never became reachable" >&2
    exit 1
  fi
  sleep 5
done

ALREADY=$(sqlplus -s -L "$CONN" <<'SQL' | tr -d '[:space:]'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT COUNT(*) FROM all_tables WHERE owner = 'BIR' AND table_name = 'ACCOUNTS';
EXIT
SQL
)

if [ "$ALREADY" = "1" ]; then
  ROWS=$(sqlplus -s -L "$CONN" <<'SQL' | tr -d '[:space:]'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT COUNT(*) FROM bir.accounts;
EXIT
SQL
)
  if [ "$ROWS" != "0" ]; then
    echo "[init] BIR schema already loaded (${ROWS} accounts). Nothing to do."
    exit 0
  fi
fi

echo "[init] creating schema ..."
sqlplus -s -L "$CONN" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
DEFINE bir_pwd = "${BIR_PWD}"
DEFINE bir_ro_pwd = "${BIR_RO_PWD}"
@/opt/oracle/sql/01_schema.sql
EXIT
SQL

echo "[init] loading data ..."
sqlplus -s -L "$CONN" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
@/opt/oracle/sql/02_seed.sql
EXIT
SQL

echo "[init] done."
