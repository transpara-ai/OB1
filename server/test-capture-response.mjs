/**
 * test-capture-response.mjs
 *
 * Unit tests for buildCaptureResult — the pure response-shaping logic for the
 * capture_thought tool. No infra (no Supabase, no Deno, no network): the I/O
 * lives in index.ts; only the decision of WHAT to return for each outcome is
 * tested here, by feeding in the (upsert, embedding) results directly.
 *
 * Run (from server/):  node test-capture-response.mjs
 */

import { buildCaptureResult } from "./capture-response.mjs";

let passed = 0;
let failed = 0;
function assert(condition, label) {
  if (condition) {
    console.log(`  ✓  ${label}`);
    passed++;
  } else {
    console.error(`  ✗  ${label}`);
    failed++;
  }
}
const textOf = (res) => res.content?.[0]?.text ?? "";

console.log("\n[1] Success — upsert committed + embedding ready");
{
  const res = buildCaptureResult({
    upsertError: null,
    thoughtId: "11111111-aaaa-bbbb-cccc-222222222222",
    embError: null,
    metadata: { type: "observation", topics: ["alpha"], people: ["Michael"] },
  });
  assert(res.isError !== true, "not an error");
  assert(textOf(res).includes("11111111-aaaa-bbbb-cccc-222222222222"), "response carries the thought id (so a client can verify by fetch(id))");
  assert(textOf(res).includes("status: committed"), "reports status: committed");
  assert(textOf(res).includes("embedding: ready"), "reports embedding: ready");
  assert(textOf(res).includes("alpha"), "keeps topics summary");
  assert(textOf(res).includes("Michael"), "keeps people summary");
}

console.log("\n[2] Embedding failure AFTER commit — must NOT be reported as failure (the false-negative fix)");
{
  const res = buildCaptureResult({
    upsertError: null,
    thoughtId: "33333333-dddd-eeee-ffff-444444444444",
    embError: { message: "embedding update timed out" },
    metadata: { type: "idea", topics: [] },
  });
  assert(res.isError !== true, "NOT an error — the thought is durably committed");
  assert(textOf(res).includes("33333333-dddd-eeee-ffff-444444444444"), "still carries the thought id");
  assert(textOf(res).includes("embedding: pending"), "reports embedding: pending");
  assert(/saved|retrievable|backfill/i.test(textOf(res)), "tells the caller the thought IS saved/retrievable");
  assert(textOf(res).includes("embedding update timed out"), "surfaces the embedding error reason");
}

console.log("\n[3] Upsert failure — the durable write did not land → error");
{
  const res = buildCaptureResult({
    upsertError: { message: "duplicate key value violates unique constraint" },
    thoughtId: null,
    embError: null,
    metadata: {},
  });
  assert(res.isError === true, "is an error");
  assert(textOf(res).includes("Failed to capture"), "says capture failed");
  assert(textOf(res).includes("duplicate key"), "surfaces the upsert error reason");
}

console.log("\n[4] Committed but NO id returned — unverifiable → fail closed (error, never silent success)");
{
  const res = buildCaptureResult({
    upsertError: null,
    thoughtId: null,
    embError: null,
    metadata: {},
  });
  assert(res.isError === true, "is an error (cannot confirm persistence without an id)");
  assert(/unconfirmed/i.test(textOf(res)) && /id/i.test(textOf(res)), "explains it is unconfirmed for lack of an id");
}

console.log("\n[5] Embedding failure with an EMPTY message — note must not render empty parens");
{
  const res = buildCaptureResult({
    upsertError: null,
    thoughtId: "55555555-aaaa-bbbb-cccc-666666666666",
    embError: { message: "" },
    metadata: { type: "note" },
  });
  assert(res.isError !== true, "still a success — the thought is committed");
  assert(textOf(res).includes("embedding: pending"), "reports embedding: pending");
  assert(textOf(res).includes("unknown error"), "empty embedding-error message falls back to 'unknown error'");
  assert(!/failed \(\)/.test(textOf(res)), "no empty parens in the note");
}

console.log(`\n${"─".repeat(50)}`);
console.log(`${passed + failed} assertions: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("FAIL\n");
  process.exit(1);
} else {
  console.log("PASS\n");
}
