# Supabase → Local Docker Migration

Move your `public.thoughts` data from a cloud-resident Supabase project into
the local Docker stack in `integrations/local-docker/`.

The workflow is intentionally boring: `pg_dump --data-only` on the source,
`psql` on the target. No app-layer code; no ETL; no embedding recomputation.

## Why this works

The local schema in `../db-init/01-schema.sql` is a column-for-column mirror
of the canonical Supabase schema documented in `docs/01-getting-started.md`
(same `uuid` PK, same columns, same `content_fingerprint`). So a vanilla
`pg_dump --data-only --table=public.thoughts` from Supabase restores cleanly.

The `embedding vector(1536)` column is serialised as `'[0.1, 0.2, ...]'`
text literals by `pg_dump`; the local `pgvector` extension parses those
back into `vector` values on insert. No re-embedding needed.

## Prerequisites

- Local stack running: `docker compose up -d` (from `integrations/local-docker/`)
- `.env` filled in (so the import script knows the DB credentials)
- `pg_dump` **version 15 or 16** on your machine, matching Supabase's Postgres
  major version. Mismatched majors refuse to dump.
  - macOS: `brew install postgresql@16`
  - Debian/Ubuntu: `apt install postgresql-client-16`
- Your Supabase **direct** connection URI — not the pooler:
  Dashboard → Settings → Database → "Connection string" → "URI"
  `postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres`

## Steps

### 1. Export from Supabase

```bash
cd integrations/local-docker/migrate
export SUPABASE_DB_URL='postgresql://postgres:...@db.xxxx.supabase.co:5432/postgres'
./01-export-from-supabase.sh
# → dumps/thoughts-20260417T120000Z.sql
```

This writes a plain-SQL, data-only dump with `--column-inserts` (one
`INSERT` per row, not `COPY`), which is slower to load but easier to
inspect, partially apply, or transform if anything goes wrong.

### 2. Import into the local stack

```bash
./02-import-to-local.sh ./dumps/thoughts-20260417T120000Z.sql
```

The script:
1. Sources `.env` from the parent integration directory for local DB creds.
2. Checks `public.thoughts` exists (schema was bootstrapped).
3. Wraps the load in `DISABLE TRIGGER thoughts_updated_at` /
   `ENABLE TRIGGER` so historical `updated_at` values survive the insert.
4. Prints before/after row counts.

### 3. Verify

```bash
psql "postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:$POSTGRES_PORT/$POSTGRES_DB" \
  -f 03-verify.sql
```

You should see:
- Row count matching Supabase
- All rows have `embedding` populated
- All rows have `content_fingerprint` populated (if you ran the dedup recipe
  on Supabase before exporting)
- Zero duplicate fingerprints
- Both `match_thoughts` and `upsert_thought` functions present

### 4. Smoke test the MCP server

```bash
curl -s "http://127.0.0.1:${MCP_PORT}/mcp?key=${MCP_ACCESS_KEY}" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq .
```

Or point Claude Desktop / Claude Code at `http://127.0.0.1:8000/mcp?key=...`
and run a semantic search — you should get hits from your migrated data.

## Gotchas

- **Don't re-run the import.** The dump uses `INSERT`, not upsert; re-running
  will fail on the `id` primary key. If you need a clean retry:
  `psql $LOCAL_URL -c 'TRUNCATE public.thoughts;'` first.
- **Extensions (job-hunt, professional-crm, meal-planning) are not migrated**
  by this script. They use `auth.uid()` in their RLS policies and reference
  `auth.users` — they need a separate auth-layer decision before migrating.
  See the Phase 2 notes in the parent `README.md`.
- **`pg_dump` version mismatch** produces an unhelpful error. If you see
  `server version: 16.x; pg_dump version: 15.x`, install the matching
  client. Supabase projects created in 2025+ are Postgres 16.
- **Large tables** (&gt;100k rows): `--column-inserts` becomes slow. Switch
  to the default `COPY` format by removing that flag in
  `01-export-from-supabase.sh` — imports in seconds instead of minutes,
  at the cost of less-readable dumps.
