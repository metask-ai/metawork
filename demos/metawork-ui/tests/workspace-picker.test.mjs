import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { buildSync } from "esbuild";

const result = buildSync({
  stdin: {
    contents: `
      export * from './src/demo/workspace-picker.ts';
      export { BridgeClient } from './src/demo/client.ts';
      export { demo, snapshot } from './src/demo/state.ts';
      export { chooseWorkspaceAndMigrateDraft } from './src/features/workspaces/chooseWorkspace.ts';
    `,
    resolveDir: new URL("..", import.meta.url).pathname,
  },
  bundle: true,
  platform: "node",
  format: "cjs",
  write: false,
  define: { "import.meta.env.DEV": "false" },
});
const compiled = { exports: {} };
new Function("require", "module", "exports", result.outputFiles[0].text)(
  createRequire(import.meta.url),
  compiled,
  compiled.exports,
);
const {
  BridgeClient,
  demo,
  snapshot,
  requestDemoWorkspace,
  getWorkspacePickerRequest,
  addDemoWorkspace,
  cancelDemoWorkspace,
  selectDemoWorkspace,
  subscribeWorkspacePicker,
  chooseWorkspaceAndMigrateDraft,
} = compiled.exports;

test("real demo bridge waits for a choice; cancel preserves the source draft", async () => {
  const client = new BridgeClient();
  const count = demo.workspaces.length;
  let settled = false;
  let refreshed = false;
  let moved = false;
  const operation = chooseWorkspaceAndMigrateDraft({
    choose: () => client.chooseWorkspace(),
    refresh: async () => {
      refreshed = true;
    },
    migratableDraftId: "unscoped",
    moveDraft: () => {
      moved = true;
    },
  });
  operation.then(() => {
    settled = true;
  });
  await Promise.resolve();
  assert.ok(getWorkspacePickerRequest());
  assert.equal(settled, false);
  cancelDemoWorkspace();
  assert.deepEqual(await operation, { kind: "cancelled" });
  assert.equal(demo.workspaces.length, count);
  assert.equal(refreshed, false);
  assert.equal(moved, false);
});

test("adding registers a unique workspace before refresh and draft migration", async () => {
  const client = new BridgeClient();
  const existingIds = new Set(demo.workspaces.map((workspace) => workspace.id));
  const steps = [];
  const operation = chooseWorkspaceAndMigrateDraft({
    choose: () => client.chooseWorkspace(),
    refresh: async () => {
      assert.ok(
        snapshot(demo.scope).workspaces.some(
          (workspace) => workspace.displayName === "QA 新项目",
        ),
      );
      steps.push("refresh");
    },
    migratableDraftId: "unscoped",
    moveDraft: (source, target) => {
      steps.push([source, target]);
    },
  });
  assert.equal(addDemoWorkspace("  QA 新项目  "), true);
  const outcome = await operation;
  const workspace = demo.workspaces.find(
    (item) => item.id === outcome.result.workspaceId,
  );
  assert.equal(outcome.kind, "selected");
  assert.equal(existingIds.has(workspace.id), false);
  assert.equal(workspace.canonicalRoot, "/Demo/QA 新项目");
  assert.equal(workspace.authorization, "available");
  assert.equal(workspace.kind, "manual");
  assert.deepEqual(steps, ["refresh", ["unscoped", workspace.id]]);
  assert.equal(getWorkspacePickerRequest(), null);
});

test("existing names are selected without duplicate workspaces; double-submit is harmless", async () => {
  const count = demo.workspaces.length;
  const promise = requestDemoWorkspace();
  assert.equal(addDemoWorkspace("QA 新项目"), true);
  assert.equal(addDemoWorkspace("QA 新项目"), false);
  const choice = await promise;
  assert.equal(
    choice.workspaceId,
    demo.workspaces.find((item) => item.displayName === "QA 新项目").id,
  );
  assert.equal(demo.workspaces.length, count);
});

test("invalid names and unavailable selections leave the picker open without changing state", async () => {
  const count = demo.workspaces.length;
  const promise = requestDemoWorkspace();
  for (const name of [
    "",
    "   ",
    ".",
    "..",
    "bad/name",
    "bad\\name",
    "bad\u0001name",
    "x".repeat(81),
  ])
    assert.equal(addDemoWorkspace(name), false);
  assert.equal(selectDemoWorkspace("unknown"), false);
  const workspace = demo.workspaces[0];
  workspace.authorization = "reauthorization_required";
  assert.equal(selectDemoWorkspace(workspace.id), false);
  workspace.authorization = "available";
  assert.ok(getWorkspacePickerRequest());
  assert.equal(demo.workspaces.length, count);
  cancelDemoWorkspace();
  assert.deepEqual(await promise, { selected: false });
});

test("repeated requests share one dialog; a later request can select a different workspace", async () => {
  let changes = 0;
  const unsubscribe = subscribeWorkspacePicker(() => {
    changes++;
  });
  const first = requestDemoWorkspace();
  assert.equal(requestDemoWorkspace(), first);
  assert.equal(changes, 1);
  selectDemoWorkspace("2");
  assert.deepEqual(await first, { selected: true, workspaceId: "2" });
  assert.equal(changes, 2);
  const second = requestDemoWorkspace();
  unsubscribe();
  cancelDemoWorkspace();
  assert.deepEqual(await second, { selected: false });
  assert.equal(changes, 3);
});
