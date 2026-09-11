import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { join } from "node:path";
import test from "node:test";

import { createServer } from "vite";

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { parseUnifiedDiff } = await vite.ssrLoadModule(
  "/src/features/tasks/unified-diff.ts",
);

test.after(async () => vite.close());

test("parses metadata, a first-hunk gap, dual line numbers, and markers", () => {
  const rows = parseUnifiedDiff(
    [
      "diff --git a/src/main.ts b/src/main.ts",
      "index 1111111..2222222 100644",
      "--- a/src/main.ts",
      "+++ b/src/main.ts",
      "@@ -17,2 +17,2 @@ export function value() {",
      "-  return 'old';",
      "+  return 'new';",
      " }",
      "\\ No newline at end of file",
    ].join("\n"),
  );

  assert.deepEqual(
    rows.slice(0, 4).map((row) => row.kind),
    ["metadata", "metadata", "metadata", "metadata"],
  );
  assert.deepEqual(rows[4], { kind: "gap", count: 16 });
  assert.equal(rows[5].kind, "hunk");
  assert.deepEqual(rows[6], {
    kind: "deletion",
    text: "-  return 'old';",
    oldLine: 17,
    newLine: null,
  });
  assert.deepEqual(rows[7], {
    kind: "addition",
    text: "+  return 'new';",
    oldLine: null,
    newLine: 17,
  });
  assert.deepEqual(rows[8], {
    kind: "context",
    text: " }",
    oldLine: 18,
    newLine: 18,
  });
  assert.equal(rows[9].kind, "no-newline");
});

test("shows only provable equal unchanged gaps between valid hunks", () => {
  const rows = parseUnifiedDiff(
    [
      "@@ -1,2 +1,2 @@",
      " same",
      "-old",
      "+new",
      "@@ -10 +10 @@",
      "-later",
      "+updated",
    ].join("\n"),
  );
  assert.deepEqual(
    rows.filter((row) => row.kind === "gap"),
    [{ kind: "gap", count: 7 }],
  );
  assert.deepEqual(
    rows.filter((row) => row.kind === "hunk").map((row) => row.text),
    ["@@ -1,2 +1,2 @@", "@@ -10 +10 @@"],
  );
});

test("preserves visible line semantics in malformed hunks without invented coordinates", () => {
  const rows = parseUnifiedDiff(
    [
      "@@ -1,2 +1,2 @@",
      "-old",
      "+new",
      "@@ -100 +100 @@",
      "-later",
      "+updated",
      "@@ -999999999999999999999 +1 @@",
    ].join("\n"),
  );
  assert.deepEqual(
    rows.slice(0, 3).map((row) => row.kind),
    ["hunk", "deletion", "addition"],
  );
  assert.deepEqual(rows[1], {
    kind: "deletion",
    text: "-old",
    oldLine: null,
    newLine: null,
  });
  assert.deepEqual(rows[2], {
    kind: "addition",
    text: "+new",
    oldLine: null,
    newLine: null,
  });
  assert.equal(
    rows.some((row) => row.kind === "gap"),
    false,
  );
  assert.equal(rows.filter((row) => row.kind === "hunk").length, 2);
  assert.deepEqual(rows.at(-1), {
    kind: "raw",
    text: "@@ -999999999999999999999 +1 @@",
  });
});

test("normalizes CRLF separators without changing diff content", () => {
  const rows = parseUnifiedDiff("@@ -2 +2 @@\r\n-old\r\n+new\r\n");
  assert.deepEqual(
    rows.map((row) => row.kind),
    ["gap", "hunk", "deletion", "addition"],
  );
  assert.equal(rows[2].text, "-old");
  assert.equal(rows[3].text, "+new");
});

test("parses a near-limit recorded diff in one bounded pass", () => {
  const count = 2_000;
  const content = [
    `@@ -1,${count} +1,${count} @@`,
    ...Array.from(
      { length: count },
      (_, index) => ` ${String(index).padStart(4, "0")} ${"x".repeat(112)}`,
    ),
  ].join("\n");
  assert.ok(Buffer.byteLength(content) <= 256 * 1024);

  const started = performance.now();
  const rows = parseUnifiedDiff(content);
  const elapsed = performance.now() - started;

  assert.equal(rows.length, count + 1);
  assert.equal(rows.at(-1).oldLine, count);
  assert.equal(rows.at(-1).newLine, count);
  assert.ok(elapsed < 2_000, `parser took ${elapsed.toFixed(1)} ms`);
});
