-- Open Brain schema for local Docker PostgreSQL + pgvector.
-- This mirrors the canonical Supabase schema in docs/01-getting-started.md
-- (uuid PK, updated_at trigger, content_fingerprint dedup, match_thoughts,
-- upsert_thought) so a pg_dump --data-only from Supabase restores cleanly.
--
-- RLS is NOT enabled here: local Docker has no `auth` schema and no JWTs.
-- Access control is handled at the application layer (MCP_ACCESS_KEY on the
-- server, host-local port binding on Postgres).

CREATE EXTENSION IF NOT EXISTS vector;

-- --- Core table ----------------------------------------------------------

CREATE TABLE IF NOT EXISTS thoughts (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content              text NOT NULL,
  embedding            vector(1536),
  metadata             jsonb DEFAULT '{}'::jsonb,
  content_fingerprint  text,
  created_at           timestamptz DEFAULT now(),
  updated_at           timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_thoughts_embedding_hnsw
  ON thoughts USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_thoughts_metadata
  ON thoughts USING gin (metadata);

CREATE INDEX IF NOT EXISTS idx_thoughts_created_at
  ON thoughts (created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_thoughts_fingerprint
  ON thoughts (content_fingerprint)
  WHERE content_fingerprint IS NOT NULL;

-- --- updated_at trigger --------------------------------------------------

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS thoughts_updated_at ON thoughts;
CREATE TRIGGER thoughts_updated_at
  BEFORE UPDATE ON thoughts
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- --- Semantic search RPC -------------------------------------------------

CREATE OR REPLACE FUNCTION match_thoughts(
  query_embedding  vector(1536),
  match_threshold  float   DEFAULT 0.7,
  match_count      int     DEFAULT 10,
  filter           jsonb   DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  id          uuid,
  content     text,
  metadata    jsonb,
  similarity  float,
  created_at  timestamptz
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.id,
    t.content,
    t.metadata,
    1 - (t.embedding <=> query_embedding) AS similarity,
    t.created_at
  FROM thoughts t
  WHERE 1 - (t.embedding <=> query_embedding) > match_threshold
    AND (filter = '{}'::jsonb OR t.metadata @> filter)
  ORDER BY t.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;

-- --- Dedup upsert RPC ----------------------------------------------------

CREATE OR REPLACE FUNCTION upsert_thought(
  p_content  text,
  p_payload  jsonb DEFAULT '{}'
)
RETURNS jsonb AS $$
DECLARE
  v_fingerprint text;
  v_id          uuid;
BEGIN
  v_fingerprint := encode(sha256(convert_to(
    lower(trim(regexp_replace(p_content, '\s+', ' ', 'g'))),
    'UTF8'
  )), 'hex');

  INSERT INTO thoughts (content, content_fingerprint, metadata)
  VALUES (p_content, v_fingerprint, COALESCE(p_payload->'metadata', '{}'::jsonb))
  ON CONFLICT (content_fingerprint) WHERE content_fingerprint IS NOT NULL DO UPDATE
    SET updated_at = now(),
        metadata   = thoughts.metadata || COALESCE(EXCLUDED.metadata, '{}'::jsonb)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'fingerprint', v_fingerprint);
END;
$$ LANGUAGE plpgsql;
