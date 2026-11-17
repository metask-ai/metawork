import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

function zigFiles(prefix) {
  const found = [];
  const walk = (dir) => {
    for (const entry of readdirSync(new URL(dir, root), {
      withFileTypes: true,
    })) {
      const path = join(dir, entry.name).replaceAll("\\", "/");
      if (entry.isDirectory()) walk(`${path}/`);
      else if (entry.name.endsWith(".zig")) found.push(path);
    }
  };
  walk(prefix);
  return found.sort();
}

/**
 * Every independent Completion a MetaWork owner starts outside AgentCore, and
 * the module that starts it.
 *
 * These are the only places a Metask credential reaches a model without going
 * through a Run, so they are exactly the set the execution split has to place
 * on one side or the other. The set was a prose rule in the architecture and
 * nothing checked it, which is how the approval reviewer stayed off the
 * ownership list through several rounds of review: a sentence that lists four
 * things cannot notice a fifth.
 *
 * A new entry here is a new credential holder and a new renewal point, which
 * is the shape of the gap #175 came from. Adding one should require editing
 * this list and the architecture together.
 */
const expected_sites = [
  "src/product/control/runtime.zig",
  "src/product/task/execution.zig",
];

// KNOWN LIMITATION, deliberately recorded rather than left to be rediscovered.
//
// This scan is anchored on the consumer's spelling, and the repository already
// contains a shape that walks past it: src/product/control/runtime.zig around
// line 8394 forwards `completion_factory.context` and `.create_fn` into
// `task/execution.zig`'s own `CompletionFactory`, which is a second type with
// the same name. Another re-wrap under a different field name would be
// invisible here.
//
// The tighter anchor is the producer, and there is exactly one: `createCompletion`
// is defined once in src/app/completion_http_transport.zig and handed over once
// in src/app.zig. Pinning those two counts, alongside this scan, leaves far less
// spelling freedom than "whatever the field is called". Scheduled with the next
// change to this guard; until then, read this test as "no new consumer spelling",
// not as "no new holder".
test("the independent Completion holders are exactly the recorded set", () => {
  const sites = zigFiles("src/").filter((path) =>
    /completion_factory\.create\(/.test(read(path)),
  );
  assert.deepEqual(
    sites,
    expected_sites,
    "a module started an independent Completion without being recorded in " +
      "scripts/completion-credential-holders.test.mjs; it is a new Metask " +
      "credential holder, so place it in docs/architecture.md section 5 too",
  );
});

test("each holder is named on the execution side by the architecture", () => {
  const architecture = read("docs/architecture.md");
  const ownership = architecture.slice(architecture.indexOf("模块归属上"));
  assert.ok(ownership.length > 0, "the module ownership paragraph is gone");
  // One phrase per credential-bearing model entry. A holder that is not named
  // here has no recorded side, which is the state the approval reviewer was in.
  for (const entry of [
    "Run 本身",
    "compaction",
    "自动标题",
    "自动审批",
    "图像",
    "视频",
  ]) {
    assert.ok(
      ownership.includes(entry),
      `the architecture's ownership paragraph does not name ${entry}`,
    );
  }
});

test("the approval reviewer redacts before it builds the request", () => {
  // The reviewer's input carries tool arguments and user history. Today the
  // scrub runs first and the Completion is built from the scrubbed copy; once
  // the model call lives in another process that order is what keeps
  // unredacted history from crossing, so it is pinned rather than remembered.
  const control = read("src/product/control/runtime.zig");
  const scrub = control.indexOf("try self.scrubPermissionArguments(");
  const create = control.indexOf("self.completion_factory.create(");
  assert.ok(scrub !== -1, "the permission argument scrub is gone");
  assert.ok(create !== -1, "the reviewer's Completion creation is gone");
  assert.ok(
    scrub < create,
    "the permission scrub must run before the reviewer's request is built, " +
      "or unredacted user history crosses the process boundary",
  );
});

test("a Run's own credential reaches the model as a bounded copy", () => {
  // The two holders are not symmetric today: the title job copies the
  // credential and releases it, the reviewer passes the stored key straight
  // through. Recorded so the move does not carry the weaker shape across.
  const execution = read("src/product/task/execution.zig");
  assert.match(execution, /\.copy\(std\.heap\.c_allocator\)/);
  assert.match(execution, /defer credential\.deinit\(\);/);
});
