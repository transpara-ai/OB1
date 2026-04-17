#!/usr/bin/env bash
# Export the `thoughts` table data from a Supabase project as a
# plain-SQL, data-only dump that can be replayed into the local
# Docker stack (schema already bootstrapped from db-init/).
#
# Requires: pg_dump (matching major version of the Supabase Postgres,
# v15 or v16 — `brew install postgresql@16` or `apt install postgresql-client-16`).
#
# Get SUPABASE_DB_URL from Supabase dashboard:
#   Settings → Database → Connection string → "URI" (direct connection,
#   NOT the pooler). It looks like:
#     postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres

set -euo pipefail

: "${SUPABASE_DB_URL:?set SUPABASE_DB_URL to your Supabase direct connection URI}"

OUT_DIR="$(cd "$(dirname "$0")" && pwd)/dumps"
mkdir -p "$OUT_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUT_DIR/thoughts-${STAMP}.sql"

echo "Exporting public.thoughts from Supabase → $OUT_FILE"

pg_dump \
  --dbname="$SUPABASE_DB_URL" \
  --data-only \
  --table=public.thoughts \
  --no-owner \
  --no-privileges \
  --column-inserts \
  --format=plain \
  --file="$OUT_FILE"

ROWS=$(grep -c '^INSERT INTO public.thoughts' "$OUT_FILE" || true)
echo "Done. $ROWS INSERT statements written."
echo ""
echo "Next:"
echo "  ./02-import-to-local.sh \"$OUT_FILE\""
