import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

import { BridgeClient } from "../frontend/src/bridge/client.ts";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
const {
  cleanup,
  fireEvent,
  render: renderDom,
  screen,
  waitFor,
  within,
} = await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { ScheduledTasksPage } = await vite.ssrLoadModule(
  "/src/features/scheduled-tasks/ScheduledTasksPage.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

function scheduledElement(snapshot, overrides = {}) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(ScheduledTasksPage, {
      snapshot,
      disabled: false,
      recoveryDisabled: false,
      onCreate: async () => undefined,
      onUpdate: async () => undefined,
      onSetEnabled: async () => undefined,
      onRunNow: async () => ({ taskId: "3" }),
      onDelete: async () => undefined,
      onRecover: async () => ({ outcome: "recovered" }),
      onOpenTask() {},
      ...overrides,
    }),
  );
}

function render(snapshot) {
  return renderToStaticMarkup(scheduledElement(snapshot));
}

async function chooseTime(user, value) {
  const picker = screen.getByRole("group", { name: "Time" });
  await user.click(within(picker).getByRole("button"));
  for (const [index, label] of ["Hours", "Minutes"].entries()) {
    const column = await screen.findByRole("radiogroup", { name: label });
    await user.click(
      within(column).getByRole("radio", {
        name: value.split(":")[index],
        exact: true,
      }),
    );
  }
  await user.keyboard("{Escape}");
  await waitFor(() =>
    assert.ok(screen.queryByRole("radiogroup", { name: "Hours" }) === null),
  );
}

async function chooseFrequency(user, label) {
  await user.click(screen.getByRole("button", { name: "Repeat", exact: true }));
  await user.click(
    await screen.findByRole("menuitem", { name: label, exact: true }),
  );
  if (label === "Weekly" || label === "Monthly") {
    await screen.findAllByRole("menuitemcheckbox");
    assert.match(
      screen.getByRole("button", { name: "Repeat", exact: true }).textContent,
      new RegExp(label),
    );
  }
  for (let i = 0; i < 3 && screen.queryAllByRole("menu").length; i++)
    await user.keyboard("{Escape}");
}

function scheduleSnapshot(overrides = {}) {
  const snapshot = structuredClone(fixture);
  Object.assign(snapshot.capabilities, {
    automaticWorkspaces: true,
    scheduledTasks: true,
    scheduledTaskPersistence: true,
    scheduledTaskPersistenceHealth: "ready",
    backgroundScheduleWake: true,
  });
  snapshot.scheduledTasks = [
    {
      id: "8",
      epoch: "1",
      title: "Review",
      titleRedacted: false,
      permissionProfile: "approval_required",
      enabled: true,
      health: "ready",
      failureReason: null,
      binding: {
        status: "bound",
        modelRef: { sourceId: "metask", modelId: "old-model" },
        sourceGeneration: "1",
        protocol: "anthropic_messages",
      },
      input: {
        kind: "text",
        text: "Review every line\nAnd explain the result",
        redacted: false,
      },
      recurrence: {
        kind: "interval",
        startAtUnixSeconds: "1800000000",
        everySeconds: "3600",
      },
      nextRunAtUnixSeconds: "1800000000",
      occurrences: [],
      ...overrides,
    },
  ];
  return snapshot;
}

test("attention explains its cause and requires confirmation while deletion stays available", async () => {
  let updated;
  let deleted = 0;
  const snapshot = scheduleSnapshot({
    enabled: false,
    health: "needs_attention",
    failureReason: "execution_changed",
    nextRunAtUnixSeconds: null,
  });
  renderDom(
    scheduledElement(snapshot, {
      onUpdate: async (...args) => {
        updated = args;
      },
      onDelete: async () => {
        deleted++;
      },
    }),
  );
  assert.match(
    document.body.textContent,
    /The model or connection changed\. Edit and confirm\./,
  );
  fireEvent.click(
    screen.getByRole("button", { name: /Review.*Review every line/ }),
  );
  for (const button of screen.getAllByRole("button", { name: "Run now" }))
    assert.equal(button.disabled, true);
  for (const button of screen.getAllByRole("button", { name: "Resume" }))
    assert.equal(button.disabled, true);
  assert.equal(
    screen.getByRole("button", { name: "Delete schedule" }).disabled,
    false,
  );
  assert.equal(screen.getByRole("combobox", { name: "Model" }) != null, true);
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(updated));
  assert.equal(updated[2].modelSelection, null);
  fireEvent.click(
    screen.getByRole("button", { name: /Review.*Review every line/ }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Delete schedule" }));
  await waitFor(() => assert.equal(deleted, 1));
});

test("list action failures stay visible without opening an editor", async () => {
  renderDom(
    scheduledElement(scheduleSnapshot(), {
      onRunNow: async () => {
        throw new Error("internal implementation error");
      },
    }),
  );
  const user = userEvent.setup({ document });
  await user.click(
    screen.getByRole("button", { name: "Schedule actions: Review" }),
  );
  await user.click(await screen.findByRole("menuitem", { name: "Run now" }));
  await waitFor(() =>
    assert.match(
      screen.getByRole("alert").textContent,
      /could not complete this schedule change/,
    ),
  );
  assert.equal(screen.queryByRole("dialog"), null);
  assert.doesNotMatch(
    document.body.textContent,
    /internal implementation error/,
  );
});

test("expired one-time edits use the shared clock picker and recalculate at submission", async (ctx) => {
  let now = new Date("2032-01-31T12:00").getTime();
  ctx.mock.method(Date, "now", () => now);
  let saved;
  renderDom(
    scheduledElement(
      scheduleSnapshot({
        recurrence: { kind: "once", atUnixSeconds: "1000" },
        enabled: false,
        health: "completed",
        nextRunAtUnixSeconds: null,
      }),
      {
        onUpdate: async (_id, _epoch, input) => {
          saved = input;
        },
      },
    ),
  );
  const user = userEvent.setup({ document });
  await user.click(document.querySelector(".scheduled-row-main"));
  const time = screen.getByRole("group", { name: "Time" });
  assert.equal(time.getAttribute("aria-invalid"), "true");
  assert.equal(screen.queryByLabelText("Starts"), null);
  assert.equal(screen.getByRole("button", { name: "Confirm" }).disabled, true);
  await chooseTime(user, "13:00");
  assert.equal(screen.getByRole("button", { name: "Confirm" }).disabled, false);
  now = new Date("2032-02-02T14:00").getTime();
  await user.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(saved));
  assert.equal(
    saved.recurrence.atUnixSeconds,
    String(new Date("2032-02-03T13:00").getTime() / 1000),
  );
});

test("unavailable history is distinct from failure and delay retains its planned time", () => {
  const snapshot = scheduleSnapshot({
    occurrences: [
      {
        plannedAtUnixSeconds: "2000",
        triggeredAtUnixSeconds: "2100",
        source: "timer",
        result: "submitted",
        taskId: "3",
        reason: null,
        taskOutcome: "unavailable",
      },
    ],
  });
  renderDom(scheduledElement(snapshot));
  fireEvent.click(
    screen.getByRole("button", { name: /Review.*Review every line/ }),
  );
  assert.match(document.body.textContent, /Original task unavailable/);
  assert.match(document.body.textContent, /Delayed from/);
  assert.doesNotMatch(document.body.textContent, /Run failed/);
  assert.equal(screen.queryByRole("button", { name: "View result" }), null);
});

test("Scheduled tasks is a truthful independent management page", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.capabilities.backgroundScheduleWake = true;
  snapshot.scheduledTasks = [
    {
      id: "8",
      epoch: "1",
      title: "Daily repository summary",
      titleRedacted: false,
      permissionProfile: "approval_required",
      enabled: true,
      health: "ready",
      failureReason: null,
      binding: {
        status: "bound",
        modelRef: { sourceId: "metask", modelId: "fixture-model" },
        sourceGeneration: "1",
        protocol: "openai_chat_completions",
      },
      input: {
        kind: "text",
        text: "Summarize current changes",
        redacted: false,
      },
      recurrence: {
        kind: "interval",
        startAtUnixSeconds: "1800000000",
        everySeconds: "86400",
      },
      nextRunAtUnixSeconds: "1800000000",
      occurrences: [],
    },
  ];
  const html = render(snapshot);
  assert.match(html, /Scheduled tasks/);
  assert.match(html, /Continues after the window closes/);
  assert.match(html, /Search scheduled tasks/);
  assert.match(html, /type="search"/);
  assert.match(html, /1 schedule/);
  assert.match(html, /Ongoing/);
  assert.match(html, /Daily repository summary/);
  assert.match(html, /Schedule actions: Daily repository summary/);
  assert.doesNotMatch(html, /cron/i);
});

test("Empty scheduled tasks page keeps a single create entry without templates", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.capabilities.backgroundScheduleWake = true;
  const html = render(snapshot);
  assert.match(html, /No scheduled tasks yet/);
  assert.equal((html.match(/New<\/button>/g) ?? []).length, 1);
  assert.doesNotMatch(
    html,
    /Suggestions|Daily brief|Weekly review|Follow-up check/,
  );
  assert.doesNotMatch(html, /Search scheduled tasks/);
});

test("Schedule store recovery stays available when normal scheduling is blocked and requires confirmation", async () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.scheduledTasks = false;
  snapshot.capabilities.scheduledTaskPersistence = false;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "corrupt";
  snapshot.capabilities.scheduledTaskRecoveryAvailable = true;
  let recoveries = 0;
  renderDom(
    scheduledElement(snapshot, {
      disabled: true,
      recoveryDisabled: false,
      onRecover: async () => {
        recoveries += 1;
        return { outcome: "recovered" };
      },
    }),
  );

  const recovery = screen.getByRole("button", {
    name: "Start with a clean store",
  });
  assert.equal(recovery.disabled, false);
  fireEvent.click(recovery);
  assert.ok(
    screen.getByRole("alertdialog", { name: "Replace saved schedules?" }),
  );
  assert.match(
    screen.getByText(/write the schedules still available/).textContent,
    /retain the current scheduled task file.*Retired formats will not be loaded/,
  );
  fireEvent.click(screen.getByRole("button", { name: "Keep current state" }));
  assert.equal(recoveries, 0);

  fireEvent.click(recovery);
  fireEvent.click(
    screen.getByRole("button", { name: "Retain file and reset" }),
  );
  await waitFor(() => assert.equal(recoveries, 1));
});

test("Text schedules use an Automatic Workspace without requiring a Manual Workspace", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.capabilities.backgroundScheduleWake = true;
  snapshot.workspaces = [];
  snapshot.tasks = [];
  let created = null;
  renderDom(
    scheduledElement(snapshot, {
      onCreate: async (input) => {
        created = input;
      },
    }),
  );

  const newSchedule = screen.getByRole("button", { name: "New" });
  newSchedule.focus();
  fireEvent.click(newSchedule);
  const dialog = screen.getByRole("dialog", { name: "New schedule" });
  assert.equal(screen.queryByRole("button", { name: "Skill" }), null);
  assert.doesNotMatch(dialog.textContent, /workspace/i);
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Independent brief" },
  });
  fireEvent.change(
    screen.getByPlaceholderText(/Describe what MetaWork should do/),
    { target: { value: "Summarize current work" } },
  );
  await user.click(screen.getByRole("combobox", { name: "Permissions" }));
  const fullAccess = await screen.findByRole("option", {
    name: /^Full access/,
  });
  assert.match(
    fullAccess.textContent,
    /Skips routine approval; system protections still apply/,
  );
  assert.ok(fullAccess.querySelector(".selection-menu-item-leading svg"));
  await user.click(fullAccess);
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(created));
  assert.equal("target" in created, false);
  assert.equal("workspaceId" in created, false);
  assert.equal(created.input.kind, "text");
  assert.equal(created.permissionProfile, "full_access");
  assert.equal(created.modelSelection.targetModelRef.modelId, "fixture-model");
  assert.equal("protocol" in created.modelSelection, false);
});

test("schedule selection submits exact source proof independently of generic New Task admission", async () => {
  for (const source of ["metask", "custom"]) {
    for (const protocol of [
      "anthropic_messages",
      "openai_responses",
      "openai_chat_completions",
      "gemini_native",
    ]) {
      const snapshot = structuredClone(fixture);
      snapshot.capabilities.automaticWorkspaces = true;
      snapshot.capabilities.scheduledTasks = true;
      snapshot.capabilities.scheduledTaskPersistence = true;
      snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
      const provider = snapshot.models.providers[0];
      provider.sourceGeneration = "7";
      if (source === "custom") {
        snapshot.models.customProviders = [
          {
            id: "custom",
            protocol,
            sourceGeneration: "7",
            enabled: true,
            state: "ready",
            credentialStatus: "ready",
            models: [{ id: "fixture-model", ready: true }],
          },
        ];
        snapshot.models.defaultSelection = {
          sourceId: "custom",
          modelId: "fixture-model",
        };
      }
      let created = null;
      renderDom(
        scheduledElement(snapshot, {
          onCreate: async (input) => {
            created = input;
          },
        }),
      );
      fireEvent.click(screen.getByRole("button", { name: "New" }));
      fireEvent.change(screen.getByLabelText("Name"), {
        target: { value: "Work summary" },
      });
      fireEvent.change(screen.getByLabelText("Instruction"), {
        target: { value: "Summarize current work" },
      });
      const save = screen.getByRole("button", { name: "Confirm" });
      assert.equal(save.disabled, false);
      fireEvent.click(save);
      await waitFor(() => assert.ok(created));
      assert.equal("protocol" in created.modelSelection, false);
      assert.equal(created.modelSelection.expectedSourceGeneration, "7");
      assert.equal(created.modelSelection.targetModelRef.sourceId, source);
      cleanup();
    }
  }
  const stale = structuredClone(fixture);
  stale.capabilities.automaticWorkspaces = true;
  stale.capabilities.scheduledTasks = true;
  stale.capabilities.scheduledTaskPersistence = true;
  stale.capabilities.scheduledTaskPersistenceHealth = "ready";
  stale.newTaskAdmission = {
    available: false,
    reason: "workspace_unavailable",
  };
  renderDom(scheduledElement(stale));
  fireEvent.click(screen.getByRole("button", { name: "New" }));
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Work summary" },
  });
  fireEvent.change(screen.getByLabelText("Instruction"), {
    target: { value: "Summarize current work" },
  });
  assert.equal(screen.getByRole("button", { name: "Confirm" }).disabled, false);
});

test("schedule instructions have no separate Skill or Workspace configuration", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  renderDom(scheduledElement(snapshot));

  fireEvent.click(screen.getByRole("button", { name: "New" }));
  assert.equal(screen.queryByRole("button", { name: "Skill" }), null);
  assert.equal(screen.queryByLabelText(/Choose a skill/), null);
  const dialog = screen.getByRole("dialog", { name: "New schedule" });
  assert.doesNotMatch(dialog.textContent, /workspace/i);
});

test("schedule editor controls have explicit semantics and no native chrome", async () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  renderDom(scheduledElement(snapshot));

  const trigger = screen.getByRole("button", { name: "New" });
  trigger.focus();
  fireEvent.click(trigger);
  const dialog = screen.getByRole("dialog", { name: "New schedule" });
  const name = screen.getByLabelText("Name");
  await waitFor(() => assert.ok(document.activeElement === name));
  assert.equal(dialog.querySelectorAll("h2").length, 1);
  assert.doesNotMatch(dialog.textContent, /Untitled task|Times use/);
  const instruction = screen.getByLabelText("Instruction");
  const model = screen.getByRole("combobox", { name: "Model" });
  assert.ok(
    name.compareDocumentPosition(instruction) &
      Node.DOCUMENT_POSITION_FOLLOWING,
  );
  assert.ok(
    instruction.compareDocumentPosition(model) &
      Node.DOCUMENT_POSITION_FOLLOWING,
  );
  const composer = within(dialog).getByRole("region", { name: "What to run" });
  assert.ok(composer.contains(instruction));
  assert.ok(composer.contains(model));
  const permission = screen.getByRole("combobox", { name: "Permissions" });
  assert.ok(
    permission.compareDocumentPosition(model) &
      Node.DOCUMENT_POSITION_FOLLOWING,
  );
  assert.ok(
    composer.contains(screen.getByRole("combobox", { name: "Permissions" })),
  );
  assert.equal(
    screen.getByRole("combobox", { name: "Permissions" }).textContent,
    "Request approval",
  );
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(screen.getByRole("combobox", { name: "Permissions" }));
  const approval = await screen.findByRole("option", {
    name: /^Request approval/,
  });
  assert.match(
    approval.textContent,
    /Stops and needs attention when approval is required/,
  );
  assert.ok(approval.querySelector(".selection-menu-item-leading svg"));
  await user.keyboard("{Escape}");
  assert.ok(screen.getByRole("dialog", { name: "New schedule" }));
  assert.ok(screen.getByRole("heading", { level: 3, name: "When" }));
  assert.equal(dialog.querySelectorAll("fieldset, legend").length, 0);
  assert.ok(
    [...dialog.querySelectorAll("button")].every(
      (button) => button.type === "button",
    ),
  );
  assert.equal(screen.queryByRole("button", { name: "Skill" }), null);

  await user.click(screen.getByRole("button", { name: "Repeat", exact: true }));
  assert.deepEqual(
    (await screen.findAllByRole("menuitem")).map(
      (option) => option.textContent,
    ),
    ["Once", "Daily", "Weekly", "Monthly"],
  );
  await user.click(
    await screen.findByRole("menuitem", { name: "Daily", exact: true }),
  );
  assert.equal(screen.queryByRole("spinbutton", { name: "Every" }), null);
  await chooseFrequency(user, "Once");
  assert.equal(dialog.querySelectorAll("select").length, 0);
  assert.ok(dialog.querySelector('[role="combobox"]'));

  const css = readFileSync(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  assert.match(css, /input\[type="number"\][\s\S]*?appearance: textfield;/);
  assert.match(css, /::-webkit-search-cancel-button/);
  assert.match(css, /resize: none;/);
  assert.doesNotMatch(css, /\.scheduled-editor fieldset/);
  assert.ok(within(dialog).getByRole("button", { name: "Confirm" }));
  await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
  await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
  await waitFor(() => assert.ok(document.activeElement === trigger));
});

test("New task, Skills, MCP, and Scheduled tasks share one compact peer menu", async () => {
  const source = readFileSync(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  const navigation = source.match(
    /<nav\s+className="sidebar-capabilities"[\s\S]*?<\/nav>/,
  )?.[0];
  assert.ok(navigation);
  assert.ok(
    navigation.indexOf('t("task.new")') <
      navigation.indexOf('t("skills.title")'),
  );
  assert.ok(
    navigation.indexOf('t("skills.title")') <
      navigation.indexOf('t("mcp.title")'),
  );
  assert.ok(
    navigation.indexOf('t("mcp.title")') <
      navigation.indexOf('t("scheduled.title")'),
  );
  assert.equal(
    (navigation.match(/className="sidebar-capability focus-ring"/g) ?? [])
      .length,
    4,
  );
  for (const icon of ["new-task", "skills", "mcp", "scheduled-tasks"])
    assert.match(navigation, new RegExp(`<Icon name="${icon}"`));
  assert.match(navigation, /setRoute\("mcp"\)/);
  assert.doesNotMatch(navigation, /capabilities\.mcpManagement/);
  assert.match(source, /<McpPage[\s\S]*?management=\{snapshot\.mcp\}/);
  assert.doesNotMatch(
    source,
    /route === "mcp"\s*&&\s*!workbench\.snapshot\.capabilities\.mcpManagement/,
  );
});

test("Scheduled task Bridge commands preserve IDs, epochs, and exact payloads", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: {
      async invoke(command, payload) {
        calls.push({ command, payload });
        if (command.endsWith(".create"))
          return { scheduledTaskId: "8", epoch: "1", accepted: true };
        if (command.endsWith(".setEnabled"))
          return { scheduledTaskId: "8", epoch: "2", enabled: false };
        if (command.endsWith(".runNow"))
          return { scheduledTaskId: "8", taskId: "9", accepted: true };
        if (command.endsWith(".delete"))
          return { scheduledTaskId: "8", deleted: true };
        throw new Error(`unexpected command ${command}`);
      },
      on() {
        return () => undefined;
      },
    },
  });
  const mutation = {
    title: "Summary",
    binding: {
      modelRef: { sourceId: "metask", modelId: "fixture-model" },
      sourceGeneration: "1",
      protocol: "openai_chat_completions",
    },
    permissionProfile: "full_access",
    input: { kind: "text", text: "Summarize" },
    recurrence: { kind: "once", atUnixSeconds: "1800000000" },
  };
  assert.equal(
    (await client.createScheduledTask(mutation)).scheduledTaskId,
    "8",
  );
  // A requested restore can reconcile back to attention. The ACK is state,
  // not an echo of the request.
  assert.equal(
    (await client.setScheduledTaskEnabled("8", "1", true)).enabled,
    false,
  );
  assert.equal((await client.runScheduledTaskNow("8", "2")).taskId, "9");
  await client.deleteScheduledTask("8", "2");
  assert.deepEqual(
    calls.map((call) => call.command),
    [
      "metawork.scheduledTasks.create",
      "metawork.scheduledTasks.setEnabled",
      "metawork.scheduledTasks.runNow",
      "metawork.scheduledTasks.delete",
    ],
  );
  assert.deepEqual(calls[0].payload, mutation);
  assert.deepEqual(calls[1].payload, {
    scheduledTaskId: "8",
    expectedEpoch: "1",
    enabled: true,
  });
});

test("an invalid starting preference can be replaced without default admission", async () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.models.defaultSelection = {
    sourceId: "removed",
    modelId: "disabled",
  };
  snapshot.newTaskAdmission.available = false;
  let created = null;
  renderDom(
    scheduledElement(snapshot, {
      onCreate: async (input) => {
        created = input;
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "New" }));
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Work summary" },
  });
  fireEvent.change(screen.getByLabelText("Instruction"), {
    target: { value: "Summarize current work" },
  });
  assert.equal(screen.getByRole("button", { name: "Confirm" }).disabled, true);
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(screen.getByRole("combobox", { name: "Model" }));
  const candidate = snapshot.models.providers[0].models[0];
  assert.equal(
    screen.queryByRole("option", { name: "Choose a model", exact: true }),
    null,
  );
  await user.click(
    await screen.findByRole("option", {
      name: candidate.displayName,
      exact: true,
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(created));
  assert.deepEqual(created.modelSelection.targetModelRef, {
    sourceId: "metask",
    modelId: candidate.id,
  });
  assert.equal("protocol" in created.modelSelection, false);
});

function finishedOccurrence(overrides = {}) {
  return {
    plannedAtUnixSeconds: "1800000000",
    triggeredAtUnixSeconds: "1800000000",
    source: "timer",
    result: "submitted",
    taskId: "3",
    reason: null,
    taskOutcome: "completed",
    ...overrides,
  };
}

test("plan state and latest outcome stay distinct, while identical completion is shown once", () => {
  for (const health of ["paused", "needs_attention", "completed"]) {
    renderDom(
      scheduledElement(
        scheduleSnapshot({
          enabled: false,
          health,
          failureReason:
            health === "needs_attention" ? "execution_changed" : null,
          nextRunAtUnixSeconds: null,
          occurrences: [finishedOccurrence()],
        }),
      ),
    );
    const row = document.querySelector(".scheduled-list > li");
    const state = row.querySelector(".scheduled-row-next");
    assert.doesNotMatch(state.textContent, /No next run|connection changed/);
    assert.equal(
      within(row).getAllByText("Completed", { exact: true }).length,
      1,
    );
    if (health === "completed") {
      assert.equal(row.querySelector(".scheduled-row-result"), null);
    } else {
      assert.match(
        row.querySelector(".scheduled-row-result").textContent,
        /Latest run.*Completed/,
      );
      assert.doesNotMatch(state.textContent, /Completed/);
    }
    if (health === "needs_attention") {
      assert.match(
        row.querySelector(".scheduled-row-reason").textContent,
        /connection changed/,
      );
    }
    cleanup();
  }
});

test("a skipped history entry explains the blocker and links to the previous real Task", async () => {
  let opened;
  renderDom(
    scheduledElement(
      scheduleSnapshot({
        occurrences: [
          finishedOccurrence({
            result: "skipped",
            taskOutcome: null,
            reason: "previous_task_running",
          }),
        ],
      }),
      {
        onOpenTask: (id) => {
          opened = id;
        },
      },
    ),
  );
  fireEvent.click(
    screen.getByRole("button", { name: /Review.*Review every line/ }),
  );
  const history = document.querySelector(".scheduled-history");
  assert.match(history.textContent, /Skipped/);
  assert.match(
    history.querySelector(".scheduled-history-reason").textContent,
    /previous task is still running/i,
  );
  fireEvent.click(
    within(history).getByRole("button", { name: "View previous run" }),
  );
  assert.equal(opened, "3");
});

test("a changed item epoch keeps the draft and requires an explicit reload before saving", async () => {
  let updated;
  const snapshot = scheduleSnapshot();
  const overrides = {
    onUpdate: async (...args) => {
      updated = args;
    },
  };
  const view = renderDom(scheduledElement(snapshot, overrides));
  fireEvent.click(
    screen.getByRole("button", { name: /Review.*Review every line/ }),
  );
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "My unsaved name" },
  });
  const changed = scheduleSnapshot({ epoch: "2", title: "Changed elsewhere" });
  view.rerender(scheduledElement(changed, overrides));
  assert.match(screen.getByRole("alert").textContent, /schedule has changed/);
  assert.equal(screen.getByLabelText("Name").value, "My unsaved name");
  assert.equal(screen.getByRole("button", { name: "Confirm" }).disabled, true);
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  assert.equal(updated, undefined);
  fireEvent.click(screen.getByRole("button", { name: "Reload schedule" }));
  assert.equal(screen.getByLabelText("Name").value, "Changed elsewhere");
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(updated));
  assert.deepEqual(updated.slice(0, 2), ["8", "2"]);
  assert.equal(updated[2].title, "Changed elsewhere");
});

test("a confirmed local pause retains edits and adopts only the acknowledged epoch", async () => {
  let updated;
  let view;
  const overrides = {
    onUpdate: async (...args) => {
      updated = args;
    },
    onSetEnabled: async (id, epoch, enabled) => {
      assert.deepEqual([id, epoch, enabled], ["8", "1", false]);
      view.rerender(
        scheduledElement(
          scheduleSnapshot({
            epoch: "2",
            health: "paused",
            enabled: false,
            nextRunAtUnixSeconds: null,
          }),
          overrides,
        ),
      );
      return { epoch: "2" };
    },
  };
  view = renderDom(scheduledElement(scheduleSnapshot(), overrides));
  fireEvent.click(
    screen.getByRole("button", { name: /Review.*Review every line/ }),
  );
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Keep this name" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Pause" }));
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Confirm" }).disabled,
      false,
    ),
  );
  assert.equal(screen.queryByText(/schedule has changed/), null);
  assert.equal(screen.getByLabelText("Name").value, "Keep this name");
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(updated));
  assert.deepEqual(updated.slice(0, 2), ["8", "2"]);
  assert.equal(updated[2].title, "Keep this name");
});

test("new calendar choices submit their selected days and use one shared time picker", async (ctx) => {
  ctx.mock.method(Date, "now", () => new Date("2032-01-31T12:00").getTime());
  for (const [frequency, date, days] of [
    ["daily", "2032-02-01T09:30", undefined],
    ["weekly", "2032-02-07T09:30", [6]],
    ["monthly", "2032-03-31T09:30", [31]],
  ]) {
    const snapshot = scheduleSnapshot();
    snapshot.scheduledTasks = [];
    let created;
    renderDom(
      scheduledElement(snapshot, {
        onCreate: async (input) => {
          created = input;
        },
      }),
    );
    const user = userEvent.setup({ document });
    await user.click(screen.getByRole("button", { name: "New" }));
    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Calendar" },
    });
    fireEvent.change(screen.getByLabelText("Instruction"), {
      target: { value: "Inspect" },
    });
    await chooseFrequency(
      user,
      frequency[0].toUpperCase() + frequency.slice(1),
    );
    assert.equal(screen.queryByLabelText("Starts"), null);
    await chooseTime(user, "09:30");
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await waitFor(() => assert.ok(created));
    assert.deepEqual(created.recurrence, {
      kind: "calendar",
      frequency,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      startAtUnixSeconds: String(new Date(date).getTime() / 1000),
      ...(days ? { days } : {}),
    });
    cleanup();
  }
});

test("calendar edits preserve the stored recurrence", async () => {
  const recurrence = {
    kind: "calendar",
    frequency: "monthly",
    days: [1, 15, 31],
    timezone: "America/New_York",
    startAtUnixSeconds: "1793514637",
  };
  let saved;
  renderDom(
    scheduledElement(scheduleSnapshot({ recurrence }), {
      onUpdate: async (_id, _epoch, input) => {
        saved = input;
      },
    }),
  );
  fireEvent.click(document.querySelector(".scheduled-row-main"));
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Renamed" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(saved));
  assert.deepEqual(saved.recurrence, recurrence);
  assert.equal(saved.modelSelection, null);
});

test("legacy fixed intervals stay editable without being reinterpreted as calendar rules", async () => {
  const snapshot = scheduleSnapshot();
  let saved;
  renderDom(
    scheduledElement(snapshot, {
      onUpdate: async (_id, _epoch, input) => {
        saved = input;
      },
    }),
  );
  fireEvent.click(document.querySelector(".scheduled-row-main"));
  assert.match(
    screen.getByRole("button", { name: "Repeat", exact: true }).textContent,
    /Fixed interval/,
  );
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(saved));
  assert.deepEqual(saved.recurrence, snapshot.scheduledTasks[0].recurrence);
});

test("new one-time schedules choose the next local time at submission", async (ctx) => {
  let now = new Date("2032-01-31T12:00").getTime();
  ctx.mock.method(Date, "now", () => now);
  for (const [time, submitAt, expected] of [
    ["13:00", "2032-01-31T12:00", "2032-01-31T13:00"],
    ["11:00", "2032-01-31T12:00", "2032-02-01T11:00"],
    ["11:00", "2032-02-02T12:00", "2032-02-03T11:00"],
  ]) {
    now = new Date("2032-01-31T12:00").getTime();
    const snapshot = scheduleSnapshot();
    snapshot.scheduledTasks = [];
    let created;
    renderDom(
      scheduledElement(snapshot, {
        onCreate: async (input) => {
          created = input;
        },
      }),
    );
    fireEvent.click(screen.getByRole("button", { name: "New" }));
    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Reminder" },
    });
    fireEvent.change(screen.getByLabelText("Instruction"), {
      target: { value: "Summarize work" },
    });
    const clock = screen.getByRole("group", { name: "Time" });
    assert.equal(within(clock).queryByRole("textbox"), null);
    assert.equal(screen.queryByLabelText("Starts"), null);
    const user = userEvent.setup({ document: dom.window.document });
    await chooseTime(user, time);
    now = new Date(submitAt).getTime();
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
    await waitFor(() => assert.ok(created));
    assert.deepEqual(created.recurrence, {
      kind: "once",
      atUnixSeconds: String(new Date(expected).getTime() / 1000),
    });
    cleanup();
  }
});

test("one time panel contains both columns and supports keyboard navigation", async () => {
  const snapshot = scheduleSnapshot();
  snapshot.scheduledTasks = [];
  renderDom(scheduledElement(snapshot));
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(screen.getByRole("button", { name: "New" }));
  const picker = screen.getByRole("group", { name: "Time" });
  const trigger = within(picker).getByRole("button");
  assert.match(trigger.textContent, /^\d{2}:\d{2}/);
  assert.equal(within(picker).queryByRole("combobox"), null);
  await user.click(trigger);
  const panel = await screen.findByRole("dialog", { name: "Time" });
  const hours = within(panel).getByRole("radiogroup", { name: "Hours" });
  const minutes = within(panel).getByRole("radiogroup", { name: "Minutes" });
  assert.equal(within(hours).getAllByRole("radio").length, 24);
  assert.equal(within(minutes).getAllByRole("radio").length, 60);
  const selectedHour = within(hours).getByRole("radio", { checked: true });
  const nextHour = String((Number(selectedHour.textContent) + 1) % 24).padStart(
    2,
    "0",
  );
  await user.click(selectedHour);
  await user.keyboard("{ArrowDown}");
  assert.ok(
    within(hours).getByRole("radio", { name: nextHour, checked: true }),
  );
  const selectedMinute = within(minutes).getByRole("radio", { checked: true });
  const nextMinute = String(
    (Number(selectedMinute.textContent) + 1) % 60,
  ).padStart(2, "0");
  await user.click(selectedMinute);
  await user.keyboard("{ArrowDown}");
  assert.ok(
    within(minutes).getByRole("radio", { name: nextMinute, checked: true }),
  );
  assert.match(trigger.textContent, new RegExp(`${nextHour}:${nextMinute}`));
  await user.keyboard("{Escape}");
  await waitFor(() =>
    assert.ok(screen.queryByRole("dialog", { name: "Time" }) === null),
  );
  assert.ok(screen.getByRole("dialog", { name: "New schedule" }));
  await waitFor(() => assert.ok(document.activeElement === trigger));
  assert.equal(within(picker).queryByRole("textbox"), null);
});

test("weekly and monthly submenus default to today, enforce one selection, and submit sorted sets", async (ctx) => {
  ctx.mock.method(Date, "now", () => new Date("2032-01-31T12:00").getTime());
  for (const [label, defaultLabel, extraLabels, expectedDays, expectedDate] of [
    ["Weekly", "Sat", ["Wed", "Mon"], [1, 3], "2032-02-02T09:30"],
    ["Monthly", "31", ["15", "1"], [1, 15], "2032-02-01T09:30"],
  ]) {
    const snapshot = scheduleSnapshot();
    snapshot.scheduledTasks = [];
    let saved;
    renderDom(
      scheduledElement(snapshot, {
        onCreate: async (input) => {
          saved = input;
        },
      }),
    );
    const user = userEvent.setup({ document });
    await user.click(screen.getByRole("button", { name: "New" }));
    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Multiple days" },
    });
    fireEvent.change(screen.getByLabelText("Instruction"), {
      target: { value: "Inspect" },
    });
    await user.click(
      screen.getByRole("button", { name: "Repeat", exact: true }),
    );
    assert.equal(
      screen.queryByRole("menuitem", { name: "Yearly", exact: true }),
      null,
    );
    await user.click(
      await screen.findByRole("menuitem", { name: label, exact: true }),
    );
    const initial = await screen.findByRole("menuitemcheckbox", {
      name: defaultLabel,
      exact: true,
    });
    assert.equal(initial.getAttribute("aria-checked"), "true");
    assert.equal(initial.getAttribute("aria-disabled"), "true");
    await user.click(initial);
    assert.equal(initial.getAttribute("aria-checked"), "true");
    for (const name of extraLabels)
      await user.click(
        screen.getByRole("menuitemcheckbox", { name, exact: true }),
      );
    assert.equal(initial.getAttribute("aria-disabled"), null);
    await user.click(initial);
    for (let i = 0; i < 3 && screen.queryAllByRole("menu").length; i++)
      await user.keyboard("{Escape}");
    assert.match(
      screen.getByRole("button", { name: "Repeat", exact: true }).textContent,
      label === "Weekly" ? /Weekly Mon, Wed/ : /Monthly 1, 15/,
    );
    await chooseTime(user, "09:30");
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await waitFor(() => assert.ok(saved));
    assert.deepEqual(saved.recurrence.days, expectedDays);
    assert.equal(
      saved.recurrence.startAtUnixSeconds,
      String(new Date(expectedDate).getTime() / 1000),
    );
    cleanup();
  }
});

test("editing day selections and time preserves untouched rules and refills all choices", async (ctx) => {
  ctx.mock.method(Date, "now", () => new Date("2032-01-31T12:00").getTime());
  for (const [frequency, days] of [
    ["daily", undefined],
    ["weekly", [1, 3]],
    ["monthly", [1, 15, 31]],
  ]) {
    const recurrence = {
      kind: "calendar",
      frequency,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      startAtUnixSeconds: String(
        new Date("2032-01-01T08:30:37").getTime() / 1000,
      ),
      ...(days ? { days } : {}),
    };
    let saved;
    renderDom(
      scheduledElement(scheduleSnapshot({ recurrence }), {
        onUpdate: async (_id, _epoch, input) => {
          saved = input;
        },
      }),
    );
    const user = userEvent.setup({ document });
    await user.click(document.querySelector(".scheduled-row-main"));
    assert.equal(screen.queryByLabelText("Starts"), null);
    assert.ok(screen.getByRole("group", { name: "Time" }));
    if (days) {
      await user.click(
        screen.getByRole("button", { name: "Repeat", exact: true }),
      );
      await user.click(
        await screen.findByRole("menuitem", {
          name: frequency[0].toUpperCase() + frequency.slice(1),
          exact: true,
        }),
      );
      const choices = await screen.findAllByRole("menuitemcheckbox");
      assert.equal(
        choices.filter((item) => item.getAttribute("aria-checked") === "true")
          .length,
        days.length,
      );
      for (let i = 0; i < 3 && screen.queryAllByRole("menu").length; i++)
        await user.keyboard("{Escape}");
    }
    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Renamed" },
    });
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await waitFor(() => assert.ok(saved));
    assert.deepEqual(saved.recurrence, recurrence);
    await user.click(document.querySelector(".scheduled-row-main"));
    await chooseTime(user, "09:45");
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    const expected =
      frequency === "weekly" ? "2032-02-02T09:45" : "2032-02-01T09:45";
    await waitFor(() =>
      assert.equal(
        saved.recurrence.startAtUnixSeconds,
        String(new Date(expected).getTime() / 1000),
      ),
    );
    cleanup();
  }
});

test("Chinese recurrence summaries use the agreed weekday and month-day text", async () => {
  const { ScheduleRecurrencePicker } = await vite.ssrLoadModule(
    "/src/features/scheduled-tasks/ScheduleRecurrencePicker.tsx",
  );
  for (const [value, expected] of [
    ["weekly", "每周 周一、周三"],
    ["monthly", "每月 1日、15日"],
  ]) {
    const markup = renderToStaticMarkup(
      createElement(
        I18nContext.Provider,
        {
          value: {
            locale: "zh-CN",
            setLocale() {},
            t: (id, values) => translate("zh-CN", id, values),
          },
        },
        createElement(ScheduleRecurrencePicker, {
          value,
          weekdays: [1, 3],
          monthDays: [1, 15],
          onKindChange() {},
          onDaysChange() {},
        }),
      ),
    );
    assert.ok(markup.includes(expected));
  }
});

test("editing a saved weekly rule keeps its local clock and selected weekdays", async (ctx) => {
  ctx.mock.method(Date, "now", () => Date.parse("2032-01-31T12:00:00Z"));
  let saved;
  const recurrence = {
    kind: "calendar",
    frequency: "weekly",
    timezone: "America/New_York",
    days: [1, 3],
    startAtUnixSeconds: String(Date.parse("2032-01-01T08:30:37-05:00") / 1000),
  };
  renderDom(
    scheduledElement(scheduleSnapshot({ recurrence }), {
      onUpdate: async (_id, _epoch, input) => {
        saved = input;
      },
    }),
  );
  const user = userEvent.setup({ document });
  await user.click(document.querySelector(".scheduled-row-main"));
  assert.match(
    within(screen.getByRole("group", { name: "Time" })).getByRole("button")
      .textContent,
    /08:30/,
  );
  await chooseTime(user, "09:45");
  await user.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() => assert.ok(saved));
  assert.deepEqual(saved.recurrence, {
    ...recurrence,
    startAtUnixSeconds: String(Date.parse("2032-02-02T09:45:00-05:00") / 1000),
  });
});
