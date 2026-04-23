# Local Docker Self-Hosted Deployment

> **Status: Phase 1 proof-of-concept.** Covers the core `thoughts` table and
> the MCP server only. Does not yet migrate extensions (job-hunt,
> professional-crm, meal-planning) or the SvelteKit dashboard — those depend
> on Supabase Auth (`auth.uid()`) and need a separate auth-layer decision.

Run Open Brain entirely on a local Docker Compose stack — PostgreSQL +
pgvector + MCP server — as a drop-in alternative to Supabase. Reuses the MCP
server image from `../kubernetes-deployment/` so there is no duplicated code.

## What you get

- `openbrain-postgres` — `pgvector/pgvector:pg16` with the canonical
  Open Brain schema (uuid PK, `match_thoughts` RPC, `upsert_thought` RPC,
  `content_fingerprint` dedup, `updated_at` trigger). Bootstrapped
  automatically on first boot.
- `openbrain-mcp` — the Deno MCP server from `integrations/kubernetes-deployment`
  exposed on `http://127.0.0.1:8000/mcp?key=...`. Both HNSW vector search
  and raw-INSERT capture work out of the box.
- A one-shot migration workflow that moves your existing `thoughts` data
  out of Supabase with a plain `pg_dump --data-only`.

## Prerequisites

- Docker 24+ with `docker compose` v2
- ~500 MB free for the Postgres data volume (more if you have a large
  `thoughts` table)
- An OpenAI-compatible embedding/chat API (OpenRouter, OpenAI, or a local
  model with an OpenAI-compatible shim)

## Setup

### 1. Configure

```bash
cd integrations/local-docker
cp .env.example .env
# edit .env — at minimum set POSTGRES_PASSWORD, MCP_ACCESS_KEY,
# EMBEDDING_API_KEY, CHAT_API_KEY
```

### 2. Start the stack

```bash
docker compose up -d
```

On first boot, `pgvector/pgvector:pg16` runs every `*.sql` file in
`db-init/` automatically. The schema is created before `openbrain-mcp`
starts (it waits for the Postgres healthcheck).

Verify:

```bash
docker compose ps
docker compose logs postgres | grep -i "ready to accept"
docker compose logs mcp-server | tail -5
```

### 3. Point a client at it

The MCP server is a standard Streamable HTTP endpoint — same contract as
the Supabase Edge Function version. In Claude Desktop:

> Settings → Connectors → Add custom connector →
> URL: `http://127.0.0.1:8000/mcp?key=<your MCP_ACCESS_KEY>`

Or curl-test:

```bash
curl -s "http://127.0.0.1:8000/mcp?key=$MCP_ACCESS_KEY" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq .
```

### 4. Migrate existing Supabase data (optional)

See [`migrate/README.md`](./migrate/README.md). Two scripts and a verify
SQL file; the whole thing takes a few minutes for typical databases.

## How it differs from Supabase

| | Supabase deploy | Local Docker (this) |
|---|---|---|
| Hosting | Supabase Edge Functions (Deno Deploy) | Docker Compose on your host |
| DB auth | Service role JWT | `MCP_ACCESS_KEY` + host-local port |
| RLS | Enabled, `service_role` bypasses | **Disabled** — app-layer access control |
| Extensions with `auth.uid()` | Work | **Do not work** — see Phase 2 below |
| Dashboard (`dashboards/open-brain-dashboard`) | Supabase Auth | Does not apply (no Supabase Auth) |
| Air-gap compatible | No (Supabase is SaaS) | Yes (bring your own embedding model) |

## Operating notes

- **Schema changes.** `/docker-entrypoint-initdb.d/*.sql` only runs on an
  empty data volume. To iterate on the schema:
  `docker compose down -v` (destroys data) or apply migrations with
  `psql` directly.
- **Port conflicts.** Both ports bind to `127.0.0.1` only, not `0.0.0.0`.
  If something else is on 5432 or 8000, change `POSTGRES_PORT` / `MCP_PORT`
  in `.env`.
- **Backups.** `docker compose exec postgres pg_dump -U $POSTGRES_USER $POSTGRES_DB > backup.sql`
- **Server code.** Lives in `../kubernetes-deployment/index.ts`. Any fix
  there flows into this image via the Compose build context.

## Phase 2 (not included yet)

Scope for a follow-up if this PoC works:

1. **Extension migration (auth layer).** The three user-scoped extensions
   call `auth.uid()` in their RLS policies. Replace with either
   (a) a `current_setting('request.jwt.claim.sub')` shim that the MCP server
   sets per connection after validating a JWT, or (b) app-layer filtering.
2. **Dashboard migration.** `dashboards/open-brain-dashboard` uses
   `createBrowserClient()` from `@supabase/supabase-js`. Replace with an
   Auth.js / Clerk / custom JWT setup, or run in single-user mode.
3. **Capture integrations.** `integrations/slack-capture` and
   `integrations/discord-capture` POST to the Supabase Edge Function URL.
   Repoint to `http://<this host>:8000/mcp` or host them as sibling Compose
   services.
