/**
 * capture-response.mjs
 *
 * Pure response-shaping for the capture_thought tool. No I/O, no Deno, no
 * Supabase, no env — so it is importable by both the Deno edge function
 * (index.ts) and the Node unit test (test-capture-response.mjs), and its
 * behavior can be proven without infrastructure.
 *
 * The caller performs the writes and passes the OUTCOMES in:
 *   - upsertError : error from the upsert_thought RPC (null on success)
 *   - thoughtId   : id of the row, present only once the row is committed
 *   - embError    : error from the (best-effort) embedding update (null on success)
 *   - metadata    : extracted metadata { type, topics, people, action_items }
 *
 * Contract, in priority order:
 *   1. upsertError            → isError (the durable write did not land)
 *   2. committed but no id    → isError (unconfirmed: cannot be verified) — fail closed
 *   3. committed, embed failed → SUCCESS, embedding: pending (the thought IS saved;
 *                                the embedding can be backfilled). NOT an error —
 *                                reporting failure here would make callers retry and
 *                                create duplicates of an already-saved thought.
 *   4. committed, embed ok    → SUCCESS, embedding: ready
 *
 * The thought id is always included in success text so any client can verify
 * the write by calling fetch(id) rather than trusting this string.
 *
 * @param {{
 *   upsertError?: { message: string } | null,
 *   thoughtId?: string | null,
 *   embError?: { message: string } | null,
 *   metadata?: Record<string, unknown>,
 * }} outcome
 * @returns {{ content: { type: "text", text: string }[], isError?: boolean }}
 */
export function buildCaptureResult({ upsertError, thoughtId, embError, metadata } = {}) {
  // 1. Durable write failed — surface it as an error.
  if (upsertError) {
    return {
      content: [{ type: "text", text: `Failed to capture: ${upsertError.message}` }],
      isError: true,
    };
  }

  // 2. Upsert reported no error but returned no id: we cannot confirm or later
  //    verify the write. Fail closed rather than report a success we can't prove.
  if (!thoughtId) {
    return {
      content: [{
        type: "text",
        text: "Capture unconfirmed: the upsert returned no thought id, so persistence cannot be verified. Treat as NOT saved.",
      }],
      isError: true,
    };
  }

  // 3 & 4. The row is durably committed (we have an id). The embedding is
  //        best-effort: its failure does not undo the thought.
  const meta = metadata || {};
  const embeddingReady = !embError;

  let text = `Captured as ${meta.type || "thought"} (id: ${thoughtId}, status: committed, embedding: ${embeddingReady ? "ready" : "pending"})`;

  if (Array.isArray(meta.topics) && meta.topics.length)
    text += ` — ${meta.topics.join(", ")}`;
  if (Array.isArray(meta.people) && meta.people.length)
    text += ` | People: ${meta.people.join(", ")}`;
  if (Array.isArray(meta.action_items) && meta.action_items.length)
    text += ` | Actions: ${meta.action_items.join("; ")}`;

  if (!embeddingReady)
    text += ` | NOTE: the thought is saved and retrievable; the embedding update failed (${embError.message}) and can be backfilled — semantic search may miss it until then.`;

  // No isError: the thought IS durably captured.
  return { content: [{ type: "text", text }] };
}
