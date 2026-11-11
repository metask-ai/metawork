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
  "Event",
  "FocusEvent",
  "KeyboardEvent",
  "MouseEvent",
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
const { render, screen, cleanup, fireEvent, act, waitFor, within } =
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
  const dialog = await screen.findByRole("dialog", {
    name: recovery.displayName,
  });
  const heading = dialog.querySelector("h2");
  await waitFor(() => assert.ok(document.activeElement === heading));
  assert.equal(detail.mock.callCount(), 0);
  assert.equal(screen.queryByRole("button", { name: "Export .skill" }), null);
  await user.click(screen.getByRole("button", { name: "Retry", exact: true }));
  assert.equal(retries.length, 1);
  assert.equal(retries[0].installId, recovery.installId);
  await user.keyboard("{Escape}");
  assert.equal(screen.getByRole("dialog"), dialog);
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
  await waitFor(() => assert.ok(document.activeElement === card));
});

test("Skill details show the description and safely format the readable body", async (ctx) => {
  const asset = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/skill-recovery-required.fixture",
      "utf8",
    ),
  );
  const definition = [
    "# Review",
    "",
    "## Before editing",
    "",
    "Review the **selected changes**.",
    "",
    "[Reference](https://example.invalid/guide)",
    "",
    "![Diagram](https://example.invalid/diagram.png)",
    "",
    '<iframe src="https://example.invalid/embed"></iframe>',
  ].join("\r\n");
  const detail = ctx.mock.method(
    BridgeClient.prototype,
    "skillDetail",
    async () => ({
      available: true,
      definition,
      fileCount: 1,
      totalBytes: definition.length,
      reason: null,
    }),
  );
  await fixture(ctx, (snapshot) => {
    snapshot.skillManagement.assets = [
      {
        ...asset,
        installId: null,
        sourceKind: "external",
        managementState: "externally_managed",
        displayName: "pptx",
        invocationName: "pptx",
        description: "Create and edit presentations.",
      },
      {
        ...asset,
        description: "Review a project.",
        managementState: "ready",
        canExport: true,
      },
    ];
  });
  const user = userEvent.setup({ document });
  await user.click(screen.getByRole("button", { name: /pptx.*presentations/ }));
  const external = await screen.findByRole("dialog", { name: "pptx" });
  assert.ok(within(external).getByText("Create and edit presentations."));
  assert.equal(within(external).queryByText("/pptx"), null);
  assert.equal(external.querySelector("details, footer"), null);
  assert.equal(detail.mock.callCount(), 0);
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));

  await user.click(screen.getByRole("button", { name: /review.*project/i }));
  const managed = await screen.findByRole("dialog", { name: "review" });
  const content = within(managed);
  assert.ok(content.getByText("Review a project."));
  assert.ok(await content.findByRole("heading", { name: "Before editing" }));
  assert.equal(
    content.getAllByRole("heading", { name: /^review$/i }).length,
    1,
  );
  assert.equal(content.getByText("selected changes").tagName, "STRONG");
  assert.ok(content.getByText("Reference"));
  assert.equal(managed.querySelector("a[href], img, iframe, details"), null);
  assert.deepEqual(
    detail.mock.calls.map(({ arguments: args }) => args),
    [[asset.installId]],
  );
});

test("Skill details keep enablement and uninstall in the footer and move file actions into the menu", async (ctx) => {
  const asset = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/skill-recovery-required.fixture",
      "utf8",
    ),
  );
  Object.assign(asset, {
    managementState: "ready",
    canExport: true,
    canReimport: true,
    canUninstall: true,
    canSetEnabled: true,
    enabled: true,
    enablementState: "enabled",
    selectionRevision: "1",
    skillPolicyKey: "review",
  });
  const { snapshot } = await fixture(ctx, (value) => {
    value.skillManagement.assets = [asset];
  });
  const setEnabled = ctx.mock.method(
    BridgeClient.prototype,
    "setSkillEnabled",
    async () => {
      snapshot.revision = "50";
      snapshot.skillManagement.assets = [
        {
          ...asset,
          enabled: false,
          enablementState: "disabled",
          selectionRevision: "2",
        },
      ];
      return { applied: true, selectionRevision: "2", reason: null };
    },
  );
  const exportSkill = ctx.mock.method(
    BridgeClient.prototype,
    "exportSkill",
    async () => ({ exported: true, fileName: "review.skill", reason: null }),
  );
  const choose = ctx.mock.method(
    BridgeClient.prototype,
    "chooseSkillImport",
    async () => ({ status: "cancelled" }),
  );
  const user = userEvent.setup({ document });
  await user.click(
    screen.getByRole("button", { name: /review.*description/i }),
  );
  const dialog = await screen.findByRole("dialog", { name: "review" });
  const footer = within(dialog.querySelector("footer"));
  assert.deepEqual(
    footer.getAllByRole("button").map((button) => button.textContent.trim()),
    ["Disable", "Uninstall"],
  );
  await user.click(footer.getByRole("button", { name: "Disable" }));
  await footer.findByRole("button", { name: "Enable" });
  assert.deepEqual(setEnabled.mock.calls[0].arguments, [
    { scope: "personal" },
    "review",
    "disabled",
    "personal",
    "1",
  ]);
  const more = within(dialog).getByRole("button", { name: "More actions" });
  await user.click(more);
  await user.click(await screen.findByRole("menuitem", { name: "Export" }));
  await within(dialog).findByText(/Exported review.skill/);
  assert.deepEqual(exportSkill.mock.calls[0].arguments, [asset.installId]);
  await user.click(more);
  await user.click(await screen.findByRole("menuitem", { name: "Reimport" }));
  await user.click(
    await screen.findByRole("menuitem", { name: "Choose folder" }),
  );
  assert.deepEqual(choose.mock.calls[0].arguments, [
    "directory",
    { kind: "reimport", installId: asset.installId },
  ]);
});

test("Skill uninstall confirms outside the scrolling body and focuses Cancel", async (ctx) => {
  const asset = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/skill-recovery-required.fixture",
      "utf8",
    ),
  );
  Object.assign(asset, { managementState: "ready", canUninstall: true });
  const uninstall = ctx.mock.method(
    BridgeClient.prototype,
    "uninstallSkill",
    async () => ({
      accepted: true,
      installId: asset.installId,
      verificationPending: true,
      reason: null,
    }),
  );
  await fixture(ctx, (snapshot) => {
    snapshot.skillManagement.assets = [asset];
  });
  const user = userEvent.setup({ document });
  await user.click(
    screen.getByRole("button", { name: /review.*description/i }),
  );
  const detail = await screen.findByRole("dialog", { name: "review" });
  const trigger = within(detail).getByRole("button", { name: "Uninstall" });
  await user.click(trigger);
  const confirmation = await screen.findByRole("alertdialog", {
    name: "Uninstall “review”?",
  });
  const cancel = within(confirmation).getByRole("button", { name: "Cancel" });
  assert.equal(detail.contains(confirmation), false);
  assert.ok(within(confirmation).getByText(/removed from your personal/));
  await waitFor(() => assert.equal(document.activeElement, cancel));
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(document.activeElement, trigger));
  assert.equal(uninstall.mock.callCount(), 0);

  await user.click(trigger);
  await user.click(
    within(await screen.findByRole("alertdialog")).getByRole("button", {
      name: "Uninstall",
    }),
  );
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  assert.deepEqual(uninstall.mock.calls[0].arguments, [asset.installId]);
});

test("A late enablement failure stays with the Skill that initiated it", async (ctx) => {
  const builtin = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/skill-builtin.fixture",
      "utf8",
    ),
  );
  const other = {
    ...builtin,
    skillId: "builtin-pptx",
    invocationName: "pptx",
    displayName: "pptx",
    skillPolicyKey: "pptx",
  };
  const { promise, reject } = Promise.withResolvers();
  ctx.mock.method(BridgeClient.prototype, "setSkillEnabled", () => promise);
  await fixture(ctx, (snapshot) => {
    snapshot.skillManagement.assets = [builtin, other];
  });
  const user = userEvent.setup({ document });
  const open = async (name) => {
    await user.click(screen.getByRole("button", { name: new RegExp(name) }));
    return within(await screen.findByRole("dialog", { name }));
  };
  const first = await open("docx");
  await user.click(first.getByRole("button", { name: "Disable" }));
  await user.keyboard("{Escape}");
  const second = await open("pptx");
  await act(async () => reject(new Error("Host request failed")));
  assert.equal(second.queryByRole("alert"), null);
  await user.keyboard("{Escape}");
  assert.match(screen.getByRole("alert").textContent, /“docx”/);
  const reopened = await open("docx");
  assert.match(reopened.getByRole("alert").textContent, /“docx”/);
});

async function fixture(ctx, configure = () => {}) {
  const snapshot = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  snapshot.skillManagement.availability = "ready";
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
  const refreshes = [];
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
  await screen.findByRole("heading", { name: "Skills", level: 1 });
  return { snapshot, refreshes };
}

test("Catalog issues survive zero assets and search; page refresh uses the personal catalog", async (ctx) => {
  const { refreshes } = await fixture(ctx);
  const user = userEvent.setup({ document });
  assert.ok(screen.getByRole("region", { name: "Catalog issues" }));
  const search = screen.getByRole("button", { name: "Search skills" });
  await user.click(search);
  fireEvent.change(
    await screen.findByRole("searchbox", { name: "Search skills" }),
    {
      target: { value: "no-match" },
    },
  );
  assert.ok(screen.getByText(/Same-priority source conflict/));
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("searchbox"), null));
  assert.equal(search.dataset.active, "true");
  fireEvent.click(screen.getByRole("button", { name: "Refresh", exact: true }));
  assert.deepEqual(refreshes[0].args, ["personal"]);
  assert.equal(refreshes.length, 1);
  await act(async () =>
    refreshes[0].resolve({ accepted: false, reason: "catalog_unavailable" }),
  );
  assert.ok(
    await screen.findByText("The Skill catalog could not be refreshed."),
  );
});

test("The standard personal directory still reports a root error after removing compatibility controls", async (ctx) => {
  await fixture(ctx, (snapshot) => {
    snapshot.skillManagement.personalSourceDiscovery = [
      {
        sourceId: "agents.user.default",
        state: "error",
        reason: "unsupported_entry",
      },
    ];
  });
  assert.ok(
    screen.getByText(
      "Could not check the personal Skill directory: unsupported directory entry.",
    ),
  );
  assert.equal(screen.queryByRole("checkbox", { name: /Claude|Codex/ }), null);
  assert.ok(screen.getByRole("button", { name: "Import", exact: true }));
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
    scope: { kind: "personal", workspaceId: null, workspaceEpoch: null },
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
  name = "Import",
  source = "Choose folder",
) {
  await user.click(screen.getByRole("button", { name, exact: true }));
  await user.click(
    await screen.findByRole("menuitem", { name: source, exact: true }),
  );
}

test("Import uses the personal scope, retains busy confirmation and shows Host verification after one acceptance", async (ctx) => {
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
  const trigger = screen.getByRole("button", {
    name: "Import",
    exact: true,
  });
  await chooseImportMenu(user);
  await screen.findByRole("dialog");
  assert.deepEqual(choices, [["directory", { kind: "personal" }]]);
  assert.ok(screen.getByText(/Read note.txt/));
  assert.ok(screen.getByText(/A Skill named “demo” already exists/));
  assert.equal(commits.length, 0);
  assert.equal(screen.queryByRole("combobox", { name: "Install for" }), null);
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
  await waitFor(() => assert.ok(document.activeElement === trigger));
  assert.equal(commits.length, 2);
});

test("Personal import warns before taking precedence over a same-name built-in Skill", async (ctx) => {
  const builtin = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/skill-builtin.fixture",
      "utf8",
    ),
  );
  ctx.mock.method(BridgeClient.prototype, "chooseSkillImport", async () =>
    importPreparation({
      effect: "create",
      installId: null,
      invocationName: "docx",
    }),
  );
  const install = ctx.mock.method(
    BridgeClient.prototype,
    "installSkill",
    async () => ({
      accepted: false,
      installId: null,
      verificationPending: false,
      reason: "target_changed",
    }),
  );
  await fixture(ctx, (snapshot) => {
    snapshot.skillManagement.assets = [builtin];
  });
  const user = userEvent.setup({ document });
  await chooseImportMenu(user);
  const confirmation = within(await screen.findByRole("dialog"));
  assert.ok(confirmation.getByText(/personal version will take precedence/));
  assert.equal(install.mock.callCount(), 0);
  await user.click(confirmation.getByRole("button", { name: "Install Skill" }));
  assert.deepEqual(install.mock.calls[0].arguments, ["7", "2", "create"]);
});

test("A same-name unmanaged folder requires explicit replacement confirmation", async (ctx) => {
  const commits = [];
  ctx.mock.method(BridgeClient.prototype, "chooseSkillImport", async () =>
    importPreparation({ effect: "replace_directory", installId: null }),
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
  await chooseImportMenu(user);
  await screen.findByRole("dialog");
  assert.ok(screen.getByText(/A folder named “demo” already exists/));
  assert.ok(
    screen.getByText(/original copy is retained until verification finishes/),
  );
  assert.equal(
    screen.queryByRole("button", { name: "Update Skill", exact: true }),
    null,
  );
  assert.equal(commits.length, 0);
  await user.click(
    screen.getByRole("button", { name: "Replace folder", exact: true }),
  );
  assert.deepEqual(commits, [["7", "2", "replace_directory"]]);
  assert.ok(
    await screen.findByText(/The target has changed\. Choose the source again/),
  );
  await waitFor(() =>
    assert.equal(
      screen.queryByRole("button", { name: "Replace folder", exact: true }),
      null,
    ),
  );
});

test("A project import preview is discarded without offering confirmation", async (ctx) => {
  const discards = [];
  ctx.mock.method(BridgeClient.prototype, "chooseSkillImport", async () =>
    importPreparation({
      scope: { kind: "project", workspaceId: "1", workspaceEpoch: "1" },
    }),
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
  const dialog = await screen.findByRole("dialog");
  assert.equal(
    screen.queryByRole("button", { name: "Update Skill", exact: true }),
    null,
  );
  assert.ok(dialog.querySelector('[role="alert"]'));
  assert.deepEqual(discards, [["7", "2", null]]);
});

test("Late picker results are discarded after leaving the Skills page", async (ctx) => {
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
  await user.click(screen.getByRole("button", { name: "New task" }));
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
