-- Sanity checks after a Supabase → local Docker migration.
-- Run with:  psql "$LOCAL_URL" -f 03-verify.sql

\echo '=== Row count ==='
SELECT count(*) AS total_thoughts FROM public.thoughts;

\echo ''
\echo '=== Schema shape ==='
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'thoughts'
ORDER BY ordinal_position;

\echo ''
\echo '=== Embedding coverage ==='
SELECT
  count(*)                                  AS total,
  count(*) FILTER (WHERE embedding IS NOT NULL) AS with_embedding,
  count(*) FILTER (WHERE embedding IS NULL)     AS missing_embedding
FROM public.thoughts;

\echo ''
\echo '=== Fingerprint coverage ==='
SELECT
  count(*)                                            AS total,
  count(*) FILTER (WHERE content_fingerprint IS NOT NULL) AS with_fingerprint,
  count(*) FILTER (WHERE content_fingerprint IS NULL)     AS missing_fingerprint
FROM public.thoughts;

\echo ''
\echo '=== Duplicate fingerprints (should be 0) ==='
SELECT content_fingerprint, count(*) AS copies
FROM public.thoughts
WHERE content_fingerprint IS NOT NULL
GROUP BY content_fingerprint
HAVING count(*) > 1
LIMIT 5;

\echo ''
\echo '=== Date range ==='
SELECT min(created_at) AS earliest, max(created_at) AS latest FROM public.thoughts;

\echo ''
\echo '=== RPCs present ==='
SELECT proname
FROM pg_proc
WHERE proname IN ('match_thoughts', 'upsert_thought', 'update_updated_at')
ORDER BY proname;

\echo ''
\echo '=== Sample row (truncated) ==='
SELECT
  id,
  left(content, 80)         AS content_preview,
  jsonb_pretty(metadata)    AS metadata,
  content_fingerprint IS NOT NULL AS has_fingerprint,
  embedding IS NOT NULL     AS has_embedding,
  created_at
FROM public.thoughts
ORDER BY created_at DESC
LIMIT 1;
