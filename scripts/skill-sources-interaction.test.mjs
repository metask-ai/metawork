import { productStateFixture } from "./test-support/product-view-fixture.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
dom.window.PointerEvent ??= dom.window.MouseEvent;
for (const name of [
  "window",
  "document",
  "Node",
  "NodeFilter",
  "DocumentFragment",
  "Element",
  "HTMLElement",
  "HTMLButtonElement",
  "HTMLInputElement",
  "MutationObserver",
  "CustomEvent",
  "PointerEvent",
])
  globalThis[name] = name === "window" ? dom.window : dom.window[name];
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
globalThis.requestAnimationFrame = dom.window.requestAnimationFrame.bind(
  dom.window,
);
globalThis.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(
  dom.window,
);
globalThis.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
globalThis.CSS = { escape: (value) => value.replace(/["\\]/g, "\\$&") };
window.matchMedia = (query) => ({
  matches: false,
  media: query,
  addEventListener() {},
  removeEventListener() {},
});
for (const name of [
  "scrollIntoView",
  "setPointerCapture",
  "releasePointerCapture",
])
  HTMLElement.prototype[name] ??= () => {};
HTMLElement.prototype.hasPointerCapture ??= () => false;
HTMLButtonElement.prototype.getBoundingClientRect = () => ({
  x: 16,
  y: 16,
  width: 320,
  height: 36,
  top: 16,
  right: 336,
  bottom: 52,
  left: 16,
  toJSON() {
    return this;
  },
});
const { render, screen, cleanup, fireEvent, act, waitFor } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { default: App } = await vite.ssrLoadModule("/src/app/App.tsx");
const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
test.afterEach(cleanup);
test.after(async () => {
  await vite.close();
  dom.window.close();
});

test("Recovery-required details skip moving files and keep exact Retry and keyboard focus", async (ctx) => {
  const recovery = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/skill-recovery-required.fixture",
      "utf8",
    ),
  );
  recovery.canRetry = true;
  const retries = [];
  ctx.mock.method(
    BridgeClient.prototype,
    "retrySkillVerification",
    (installId) =>
      new Promise((resolve) => retries.push({ installId, resolve })),
  );
  const detail = ctx.mock.method(
    BridgeClient.prototype,
    "skillDetail",
    async () => {
      throw new Error("Recovery must not read a moving target");
    },
  );
  const { snapshot } = await fixture(
    ctx,
    (value) => (value.skillManagement.assets = [recovery]),
  );
  const user = userEvent.setup({ document });
  const card = await screen.findByRole("button", {
    name: /review.*Recovery required/,
  });
  await user.click(card);
  await screen.findByRole("dialog");
  assert.equal(detail.mock.callCount(), 0);
  assert.equal(screen.queryByRole("button", { name: "Export .skill" }), null);
  await user.click(screen.getByRole("button", { name: "Retry", exact: true }));
  assert.equal(retries.length, 1);
  assert.equal(retries[0].installId, recovery.installId);
  assert.equal(
    screen.getByRole("button", { name: "Retry", exact: true }).disabled,
    true,
  );
  snapshot.revision = "51";
  await act(async () =>
    retries[0].resolve({
      accepted: false,
      installId: recovery.installId,
      verificationPending: false,
      reason: "local_storage_failed",
    }),
  );
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Retry", exact: true }).disabled,
      false,
    ),
  );
  assert.equal(retries.length, 1);
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  assert.equal(document.activeElement, card);
});

async function fixture(ctx, configure = () => {}) {
  const snapshot = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  snapshot.skillManagement.availability = "ready";
  snapshot.skillManagement.sourceSettings.entries.forEach((entry) => {
    entry.canSetEnabled = true;
  });
  snapshot.skillManagement.assets = [];
  snapshot.skillCatalog = {
    availability: "degraded",
    revision: "personal",
    selectionRevision: "1",
    redacted: false,
    skills: [],
    issues: [{ code: "source_conflict", invocationName: "review" }],
  };
  snapshot.workspaces[0].skillCatalog = {
    ...snapshot.skillCatalog,
    issues: [],
  };
  snapshot.workspaces[0].displayName = "Project A";
  snapshot.workspaces.push({
    ...structuredClone(snapshot.workspaces[0]),
    id: "99",
    epoch: "8",
    displayName: "Project B",
  });
  const writes = [],
    recoveries = [],
    refreshes = [];
  configure(snapshot);
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onTaskOpen: () => () => {},
    onWorkbenchRevision: () => () => {},
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    setSkillSourceEnabled: (...args) =>
      new Promise((resolve, reject) => writes.push({ args, resolve, reject })),
    recoverSkillSourceSettings: (...args) =>
      new Promise((resolve) => recoveries.push({ args, resolve })),
    refreshSkillCatalog: () =>
      new Promise((resolve) => refreshes.push({ args: ["personal"], resolve })),
    refreshWorkspaceSkillCatalog: (...args) =>
      new Promise((resolve) => refreshes.push({ args, resolve })),
  }))
    ctx.mock.method(BridgeClient.prototype, name, fn);
  render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(App),
    ),
  );
  fireEvent.click(
    await screen.findByRole("button", { name: "Skills", exact: true }),
  );
  await screen.findByRole("heading", { name: "Skills", exact: true });
  return { snapshot, writes, recoveries, refreshes };
}

test("Inline brand controls retain the App mutation latch across navigation and show only committed selections", async (ctx) => {
  const { snapshot, writes } = await fixture(ctx);
  const user = userEvent.setup({ document });
  assert.equal(
    screen.queryByRole("button", { name: "Compatible sources" }),
    null,
  );
  assert.equal(screen.queryByRole("dialog"), null);
  let checkboxes = screen.getAllByRole("checkbox");
  assert.equal(checkboxes.length, 2);
  await user.click(checkboxes[0]);
  assert.deepEqual(writes[0].args, ["claude", true, "1"]);
  assert.equal(checkboxes[0].getAttribute("aria-checked"), "false");
  assert.ok(
    checkboxes.every((entry) => entry.getAttribute("aria-disabled") === "true"),
  );
  await user.click(screen.getByRole("button", { name: "MCP", exact: true }));
  await user.click(screen.getByRole("button", { name: "Skills", exact: true }));
  checkboxes = screen.getAllByRole("checkbox");
  await user.click(checkboxes[1]);
  assert.equal(writes.length, 1);
  snapshot.skillManagement.sourceSettings.revision = "2";
  snapshot.skillManagement.sourceSettings.entries[0].enabled = true;
  snapshot.skillManagement.sourceSettings.entries[1].enabled = true;
  snapshot.revision = "50";
  await act(async () =>
    writes[0].resolve({ applied: true, revision: "2", reason: null }),
  );
  await waitFor(() =>
    assert.equal(
      screen.getAllByRole("checkbox")[0].getAttribute("aria-checked"),
      "true",
    ),
  );
  await user.click(screen.getAllByRole("checkbox")[1]);
  assert.deepEqual(writes[1].args, ["codex", true, "2"]);
  await act(async () =>
    writes[1].resolve({
      applied: false,
      revision: null,
      reason: "stale_revision",
    }),
  );
  await screen.findByText(/Settings changed elsewhere/);
  assert.equal(writes.length, 2);
  assert.equal(
    screen.getAllByRole("checkbox")[1].getAttribute("aria-checked"),
    "false",
  );
});

test("committed source settings with a failed read report only the connection problem", async (ctx) => {
  const { writes } = await fixture(ctx);
  ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", async () => {
    throw new Error("source-read-unavailable");
  });
  fireEvent.click(screen.getAllByRole("checkbox")[0]);
  await act(async () =>
    writes[0].resolve({ applied: true, revision: "2", reason: null }),
  );
  await waitFor(() => assert.ok(document.querySelector(".commandbar-alert")), {
    timeout: 3500,
  });
  assert.ok(
    document.querySelector(".skill-source-controls .skill-enablement-error") ===
      null,
  );
  assert.equal(writes.length, 1);
});

test("a source reply from before a security reset cannot overwrite or release a newer request", async (ctx) => {
  const { snapshot, writes, refreshes } = await fixture(ctx);
  fireEvent.click(screen.getAllByRole("checkbox")[0]);
  snapshot.securityEpoch = "2";
  snapshot.revision = "60";
  fireEvent.click(screen.getByRole("button", { name: "Refresh", exact: true }));
  await act(async () => refreshes[0].resolve({ accepted: true, reason: null }));
  await waitFor(() =>
    assert.notEqual(
      screen.getAllByRole("checkbox")[1].getAttribute("aria-disabled"),
      "true",
    ),
  );
  fireEvent.click(screen.getAllByRole("checkbox")[1]);
  assert.equal(writes.length, 2);
  await act(async () =>
    writes[0].resolve({
      applied: false,
      revision: null,
      reason: "write_failed",
    }),
  );
  assert.ok(
    document.querySelector(".skill-source-controls .skill-enablement-error") ===
      null,
  );
  assert.equal(
    screen.getAllByRole("checkbox")[1].getAttribute("aria-disabled"),
    "true",
  );
  await act(async () =>
    writes[1].resolve({ applied: true, revision: "2", reason: null }),
  );
});

test("Unknown and oversized settings stay indeterminate and cannot be reset", async (ctx) => {
  const { snapshot, writes, recoveries } = await fixture(ctx);
  // First request returns an uncertain outcome and a new authoritative snapshot.
  fireEvent.click(screen.getAllByRole("checkbox")[0]);
  Object.assign(snapshot.skillManagement.sourceSettings, {
    revision: null,
    health: "too_large",
    entries: snapshot.skillManagement.sourceSettings.entries.map((entry) => ({
      ...entry,
      enabled: null,
      canSetEnabled: false,
    })),
    recovery: { canReread: true, canReset: false, token: "7" },
  });
  snapshot.revision = "51";
  await act(async () => writes[0].reject(new Error("timeout")));
  await screen.findByText(/Settings exceed the read limit/);
  assert.ok(
    screen
      .getAllByRole("checkbox")
      .every(
        (entry) =>
          entry.getAttribute("aria-disabled") === "true" &&
          entry.getAttribute("aria-checked") === "mixed",
      ),
  );
  assert.equal(
    screen.queryByRole("button", { name: "Turn off all compatible sources" }),
    null,
  );
  fireEvent.click(screen.getByRole("button", { name: "Reread settings" }));
  assert.deepEqual(recoveries[0].args, ["reread", "7"]);
  await act(async () =>
    recoveries[0].resolve({
      applied: false,
      revision: null,
      reason: "recovery_not_allowed",
    }),
  );
  assert.equal(writes.length, 1);
});

test("Partial persisted selections remain visible until an explicit atomic brand update succeeds", async (ctx) => {
  const { snapshot, writes } = await fixture(ctx, (value) => {
    value.skillManagement.sourceSettings.entries[0].enabled = true;
  });
  const user = userEvent.setup({ document });
  const claude = screen.getByRole("checkbox", { name: /^Claude/ });
  assert.equal(claude.getAttribute("aria-checked"), "mixed");
  assert.ok(screen.getByText("Partially enabled"));
  assert.equal(writes.length, 0);
  claude.focus();
  await user.keyboard(" ");
  assert.deepEqual(writes[0].args, ["claude", true, "1"]);
  await act(async () =>
    writes[0].resolve({
      applied: false,
      revision: null,
      reason: "write_failed",
    }),
  );
  await screen.findByText(/previous settings remain valid/);
  assert.equal(claude.getAttribute("aria-checked"), "mixed");
  await user.click(claude);
  snapshot.skillManagement.sourceSettings.entries[1].enabled = true;
  snapshot.skillManagement.sourceSettings.revision = "2";
  snapshot.revision = "52";
  await act(async () =>
    writes[1].resolve({ applied: true, revision: "2", reason: null }),
  );
  await waitFor(() =>
    assert.equal(claude.getAttribute("aria-checked"), "true"),
  );
  assert.equal(screen.queryByText("Partially enabled"), null);
  await user.click(claude);
  assert.deepEqual(writes[2].args, ["claude", false, "2"]);
  snapshot.skillManagement.sourceSettings.entries[0].enabled = false;
  snapshot.skillManagement.sourceSettings.entries[1].enabled = false;
  snapshot.skillManagement.sourceSettings.revision = "3";
  snapshot.revision = "53";
  await act(async () =>
    writes[2].resolve({ applied: true, revision: "3", reason: null }),
  );
  await waitFor(() =>
    assert.equal(claude.getAttribute("aria-checked"), "false"),
  );
});

test("Only real directory errors are shown; a missing root does not turn off the brand", async (ctx) => {
  const { writes } = await fixture(ctx, (snapshot) => {
    for (const entry of snapshot.skillManagement.sourceSettings.entries)
      entry.enabled = true;
    snapshot.skillManagement.personalSourceDiscovery = [
      { sourceId: "agents.user.default", state: "checked", reason: null },
      { sourceId: "compat.claude.user", state: "missing", reason: null },
      { sourceId: "compat.codex.user", state: "error", reason: "unreadable" },
    ];
  });
  assert.equal(
    screen
      .getByRole("checkbox", { name: "Claude" })
      .getAttribute("aria-checked"),
    "true",
  );
  assert.ok(screen.getByText(/Codex · Personal directory.*Unreadable/));
  assert.equal(screen.queryByText(/Root checked|Directory missing/), null);
  assert.equal(writes.length, 0);
});

test("Catalog issues survive zero assets and search; refreshes use the selected scope and epoch", async (ctx) => {
  const { refreshes, snapshot } = await fixture(ctx);
  const user = userEvent.setup({ document });
  assert.ok(screen.getByRole("region", { name: "Catalog issues" }));
  fireEvent.change(screen.getByRole("searchbox", { name: "Search skills" }), {
    target: { value: "no-match" },
  });
  assert.ok(screen.getByText(/Same-priority source conflict/));
  fireEvent.click(screen.getByRole("button", { name: "Refresh", exact: true }));
  assert.deepEqual(refreshes[0].args, ["personal"]);
  fireEvent.click(
    screen.getByRole("button", { name: "Project settings", exact: true }),
  );
  const refresh = screen.getByRole("button", { name: "Refresh", exact: true });
  assert.equal(refresh.disabled, false);
  fireEvent.click(refresh);
  assert.deepEqual(refreshes[1].args, [
    snapshot.workspaces[0].id,
    snapshot.workspaces[0].epoch,
  ]);
  await user.click(
    screen.getByRole("combobox", { name: "Project to configure" }),
  );
  await user.click(await screen.findByRole("option", { name: "Project B" }));
  await act(async () =>
    refreshes[1].resolve({ accepted: false, reason: "workspace_changed" }),
  );
  assert.equal(
    screen.queryByText("The Skill catalog could not be refreshed."),
    null,
  );
  fireEvent.click(screen.getByRole("button", { name: "Refresh", exact: true }));
  assert.deepEqual(refreshes[2].args, ["99", "8"]);
  await act(async () => {
    refreshes[0].resolve({ accepted: true, reason: null });
    refreshes[2].resolve({ accepted: true, reason: null });
  });
});

function importPreparation(overrides = {}) {
  return {
    status: "prepared",
    previewId: "7",
    operationId: "5",
    preparationRevision: "2",
    sourceKind: "local_directory",
    effect: "update",
    installId: "00112233445566778899aabbccddeeff",
    scope: { kind: "project", workspaceId: "1", workspaceEpoch: "1" },
    invocationName: "demo",
    displayName: "Demo Skill",
    description: "Check resources.",
    definition:
      "---\nname: demo\ndescription: Check resources.\n---\nRead note.txt.",
    fileCount: 2,
    totalBytes: 42,
    blocker: null,
    ...overrides,
  };
}
function importOperation(preparation, phase) {
  return {
    id: preparation.operationId,
    preparationRevision: preparation.preparationRevision,
    effect: preparation.effect,
    phase,
    scope: preparation.scope,
    installId: preparation.installId,
    invocationName: preparation.invocationName,
    reason: null,
    canConfirm: false,
    canDiscard: false,
    blocker: null,
  };
}
async function chooseImportMenu(
  user,
  name = "Import Skill",
  source = "Choose folder",
) {
  await user.click(screen.getByRole("button", { name, exact: true }));
  await user.click(
    await screen.findByRole("menuitem", { name: source, exact: true }),
  );
}

test("Import uses the page project, retains busy confirmation and shows Host verification after one acceptance", async (ctx) => {
  const choices = [],
    commits = [];
  const prepared = importPreparation();
  ctx.mock.method(
    BridgeClient.prototype,
    "chooseSkillImport",
    async (...args) => {
      choices.push(args);
      return prepared;
    },
  );
  ctx.mock.method(BridgeClient.prototype, "prepareSkillImport", async () => ({
    status: "cancelled",
  }));
  ctx.mock.method(
    BridgeClient.prototype,
    "installSkill",
    (...args) => new Promise((resolve) => commits.push({ args, resolve })),
  );
  const { snapshot } = await fixture(ctx);
  const user = userEvent.setup({ document });
  await user.click(
    screen.getByRole("button", { name: "Project settings", exact: true }),
  );
  const trigger = screen.getByRole("button", {
    name: "Import Skill",
    exact: true,
  });
  await chooseImportMenu(user);
  await screen.findByRole("dialog");
  assert.deepEqual(choices, [
    ["directory", { kind: "project", workspaceId: "1", workspaceEpoch: "1" }],
  ]);
  assert.ok(screen.getByText(/Read note.txt/));
  assert.equal(screen.queryByText("Replace folder"), null);
  await user.click(
    screen.getByRole("button", { name: "Update Skill", exact: true }),
  );
  assert.deepEqual(commits[0].args, ["7", "2", "update"]);
  await act(async () =>
    commits[0].resolve({
      accepted: false,
      installId: null,
      verificationPending: false,
      reason: "busy",
    }),
  );
  await screen.findByText(/related task or Skill operation is still active/);
  assert.equal(commits.length, 1);
  await user.click(
    screen.getByRole("button", { name: "Update Skill", exact: true }),
  );
  assert.deepEqual(commits[1].args, commits[0].args);
  snapshot.revision = "50";
  snapshot.skillManagement.importOperation = importOperation(
    prepared,
    "pending_verification",
  );
  await act(async () =>
    commits[1].resolve({
      accepted: true,
      installId: prepared.installId,
      verificationPending: true,
      reason: null,
    }),
  );
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  assert.ok(
    await screen.findByText(
      /demo has been published and is awaiting verification/,
    ),
  );
  await waitFor(() => assert.equal(document.activeElement, trigger));
  assert.equal(commits.length, 2);
});

test("Changing import scope obtains a new revision and explicit replacement confirmation", async (ctx) => {
  const changes = [],
    commits = [];
  ctx.mock.method(BridgeClient.prototype, "chooseSkillImport", async () =>
    importPreparation(),
  );
  ctx.mock.method(BridgeClient.prototype, "prepareSkillImport", (...args) =>
    args[2] === null
      ? Promise.resolve({ status: "cancelled" })
      : new Promise((resolve) => changes.push({ args, resolve })),
  );
  ctx.mock.method(BridgeClient.prototype, "installSkill", async (...args) => {
    commits.push(args);
    return {
      accepted: false,
      installId: null,
      verificationPending: false,
      reason: "target_changed",
    };
  });
  await fixture(ctx);
  const user = userEvent.setup({ document });
  await user.click(
    screen.getByRole("button", { name: "Project settings", exact: true }),
  );
  await chooseImportMenu(user);
  await user.click(
    await screen.findByRole("combobox", { name: "Install for" }),
  );
  await user.click(
    await screen.findByRole("option", { name: "User defaults", exact: true }),
  );
  assert.deepEqual(changes[0].args, ["7", "2", { kind: "personal" }]);
  assert.equal(screen.getByRole("button", { name: /Working/ }).disabled, true);
  await act(async () =>
    changes[0].resolve(
      importPreparation({
        preparationRevision: "3",
        scope: { kind: "personal", workspaceId: null, workspaceEpoch: null },
        effect: "replace_directory",
        installId: null,
      }),
    ),
  );
  await user.click(
    await screen.findByRole("button", { name: "Replace folder", exact: true }),
  );
  assert.deepEqual(commits, [["7", "3", "replace_directory"]]);
  await screen.findByText(/target has changed/);
  assert.equal(
    screen.queryByRole("button", { name: "Replace folder", exact: true }),
    null,
  );
  assert.equal(commits.length, 1);
});

test("Late picker results are discarded after scope navigation", async (ctx) => {
  const choices = [],
    discards = [];
  ctx.mock.method(
    BridgeClient.prototype,
    "chooseSkillImport",
    (...args) => new Promise((resolve) => choices.push({ args, resolve })),
  );
  ctx.mock.method(
    BridgeClient.prototype,
    "prepareSkillImport",
    async (...args) => {
      discards.push(args);
      return { status: "cancelled" };
    },
  );
  await fixture(ctx);
  const user = userEvent.setup({ document });
  await chooseImportMenu(user);
  await user.click(
    screen.getByRole("button", { name: "Project settings", exact: true }),
  );
  await act(async () =>
    choices[0].resolve(
      importPreparation({
        scope: { kind: "personal", workspaceId: null, workspaceEpoch: null },
      }),
    ),
  );
  assert.equal(screen.queryByRole("dialog"), null);
  assert.deepEqual(discards, [["7", "2", null]]);
});

test("Lost import response resyncs without replay and removes the consumed confirmation", async (ctx) => {
  let commits = 0;
  ctx.mock.method(BridgeClient.prototype, "chooseSkillImport", async () =>
    importPreparation({
      scope: { kind: "personal", workspaceId: null, workspaceEpoch: null },
    }),
  );
  ctx.mock.method(BridgeClient.prototype, "prepareSkillImport", async () => ({
    status: "cancelled",
  }));
  ctx.mock.method(BridgeClient.prototype, "installSkill", async () => {
    commits++;
    throw new Error("response lost");
  });
  await fixture(ctx);
  const user = userEvent.setup({ document });
  await chooseImportMenu(user);
  await user.click(
    await screen.findByRole("button", { name: "Update Skill", exact: true }),
  );
  await screen.findByText(/outcome has not been confirmed/);
  assert.equal(
    screen.queryByRole("button", { name: "Update Skill", exact: true }),
    null,
  );
  assert.equal(commits, 1);
});

test("A rolled-back operation remains visible even when the new asset was removed", async (ctx) => {
  await fixture(ctx, (snapshot) => {
    snapshot.skillManagement.importOperation = importOperation(
      importPreparation({
        scope: { kind: "personal", workspaceId: null, workspaceEpoch: null },
        effect: "create",
      }),
      "rolled_back",
    );
  });
  assert.ok(await screen.findByText(/demo failed verification.*rolled back/));
});
