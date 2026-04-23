#!/usr/bin/env bash
# Import a data-only dump from Supabase into the local Docker stack.
#
# Wraps the load in DISABLE TRIGGER / ENABLE TRIGGER so the
# `thoughts_updated_at` trigger doesn't clobber historical updated_at
# values during bulk insert.
#
# Usage:
#   ./02-import-to-local.sh ./dumps/thoughts-20260417T120000Z.sql

set -euo pipefail

DUMP="${1:-}"
if [[ -z "$DUMP" || ! -f "$DUMP" ]]; then
  echo "Usage: $0 <path-to-dump.sql>" >&2
  exit 1
fi

# Load local stack env (POSTGRES_*) from the integration's .env
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

: "${POSTGRES_USER:?POSTGRES_USER not set (check .env)}"
: "${POSTGRES_DB:?POSTGRES_DB not set (check .env)}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set (check .env)}"

LOCAL_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}"

echo "Target: postgres://${POSTGRES_USER}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}"
echo "Dump:   $DUMP"
echo ""

# Sanity: schema present?
SCHEMA_OK=$(psql "$LOCAL_URL" -tAc \
  "SELECT to_regclass('public.thoughts') IS NOT NULL")
if [[ "$SCHEMA_OK" != "t" ]]; then
  echo "ERROR: public.thoughts does not exist yet. Start the stack first:" >&2
  echo "  docker compose up -d" >&2
  exit 1
fi

# Count existing rows to detect accidental double-imports
BEFORE=$(psql "$LOCAL_URL" -tAc "SELECT count(*) FROM public.thoughts")
echo "Rows before import: $BEFORE"

psql "$LOCAL_URL" -v ON_ERROR_STOP=1 <<SQL
BEGIN;
ALTER TABLE public.thoughts DISABLE TRIGGER thoughts_updated_at;
\i $DUMP
ALTER TABLE public.thoughts ENABLE TRIGGER thoughts_updated_at;
COMMIT;
SQL

AFTER=$(psql "$LOCAL_URL" -tAc "SELECT count(*) FROM public.thoughts")
echo ""
echo "Rows after import:  $AFTER"
echo "Inserted:           $((AFTER - BEFORE))"
echo ""
echo "Verify with:  psql \"$LOCAL_URL\" -f ./03-verify.sql"
