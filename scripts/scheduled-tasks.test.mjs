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
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
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
} = await import("@testing-library/react");

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
      onCreate: async () => undefined,
      onUpdate: async () => undefined,
      onSetEnabled: async () => undefined,
      onRunNow: async () => ({ taskId: "3" }),
      onDelete: async () => undefined,
      onOpenTask() {},
      ...overrides,
    }),
  );
}

function render(snapshot) {
  return renderToStaticMarkup(scheduledElement(snapshot));
}

test("Scheduled tasks is a truthful independent management page", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
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
      enabled: true,
      health: "ready",
      failureReason: null,
      execution: {
        generation: "1",
        provider: "anthropic",
        model: "fixture-model",
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
  assert.match(html, /Run now/);
  assert.doesNotMatch(html, /cron/i);
});

test("Empty scheduled tasks page offers actionable starter templates", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.capabilities.backgroundScheduleWake = true;
  const html = render(snapshot);
  assert.match(html, /Suggestions/);
  assert.match(html, /Daily brief/);
  assert.match(html, /Weekly review/);
  assert.match(html, /Follow-up check/);
  assert.match(html, /New schedule/);
  assert.doesNotMatch(html, /What should happen automatically/);
  assert.doesNotMatch(html, /Search scheduled tasks/);
  assert.doesNotMatch(html, /Nothing is scheduled/);
});

test("starter templates hide Workspace configuration and submit target-free managed execution", async () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  let created = null;
  renderDom(
    scheduledElement(snapshot, {
      onCreate: async (input) => {
        created = input;
      },
    }),
  );

  fireEvent.click(screen.getByRole("button", { name: /Daily brief/ }));
  const dialog = screen.getByRole("dialog", { name: "Schedule editor" });
  assert.doesNotMatch(dialog.textContent, /workspace/i);
  assert.equal(screen.queryByLabelText("Workspace mode"), null);
  assert.equal(screen.queryByLabelText("Manual workspace"), null);
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.ok(created));
  assert.equal("target" in created, false);
});

test("Text schedules use a Managed Workspace without requiring a user Workspace", async () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.capabilities.backgroundScheduleWake = true;
  snapshot.selectedWorkspaceId = null;
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

  const template = screen.getByRole("button", { name: /Daily brief/ });
  assert.equal(template.disabled, false);
  fireEvent.click(template);
  const templateDialog = screen.getByRole("dialog", {
    name: "Schedule editor",
  });
  assert.doesNotMatch(templateDialog.textContent, /workspace/i);
  fireEvent.keyDown(templateDialog, {
    key: "Escape",
  });
  assert.equal(screen.queryByRole("dialog"), null);

  const newSchedule = screen.getByRole("button", { name: "New schedule" });
  newSchedule.focus();
  fireEvent.click(newSchedule);
  const dialog = screen.getByRole("dialog", { name: "Schedule editor" });
  assert.equal(screen.queryByRole("button", { name: "Skill" }), null);
  assert.doesNotMatch(dialog.textContent, /workspace/i);
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Independent brief" },
  });
  fireEvent.change(
    screen.getByPlaceholderText(/Describe what MetaWork should do/),
    { target: { value: "Summarize current work" } },
  );
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.ok(created));
  assert.equal("target" in created, false);
  assert.equal("workspaceId" in created, false);
  assert.equal(created.input.kind, "text");
});

test("schedule instructions have no separate Skill or Workspace configuration", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  renderDom(scheduledElement(snapshot));

  fireEvent.click(screen.getByRole("button", { name: "New schedule" }));
  assert.equal(screen.queryByRole("button", { name: "Skill" }), null);
  assert.equal(screen.queryByLabelText(/Choose a skill/), null);
  assert.match(
    screen.getByText(/describe that in the instruction/).textContent,
    /global Skill/,
  );
  const dialog = screen.getByRole("dialog", { name: "Schedule editor" });
  assert.doesNotMatch(dialog.textContent, /workspace/i);
});

test("schedule editor controls have explicit semantics and no native chrome", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  renderDom(scheduledElement(snapshot));

  fireEvent.click(screen.getByRole("button", { name: "New schedule" }));
  const dialog = screen.getByRole("dialog", { name: "Schedule editor" });
  const name = screen.getByLabelText("Name");
  const instruction = screen.getByLabelText("Instruction");
  assert.ok(
    name.compareDocumentPosition(instruction) &
      Node.DOCUMENT_POSITION_FOLLOWING,
  );
  assert.ok(screen.getByRole("heading", { level: 3, name: "What to run" }));
  assert.ok(screen.getByRole("heading", { level: 3, name: "When" }));
  assert.equal(dialog.querySelectorAll("fieldset, legend").length, 0);
  assert.ok(
    [...dialog.querySelectorAll("button")].every(
      (button) => button.type === "button",
    ),
  );
  assert.equal(screen.queryByRole("button", { name: "Skill" }), null);

  fireEvent.click(screen.getByRole("button", { name: "Repeat" }));
  assert.ok(screen.getByLabelText("Every"));
  assert.ok(screen.getByLabelText("Interval unit"));
  for (const select of dialog.querySelectorAll("select"))
    assert.equal(select.parentElement.className, "scheduled-select");

  const css = readFileSync(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  assert.match(css, /\.scheduled-select select \{[\s\S]*?appearance: none;/);
  assert.match(css, /input\[type="number"\][\s\S]*?appearance: textfield;/);
  assert.match(css, /::-webkit-search-cancel-button/);
  assert.match(css, /resize: none;/);
  assert.match(css, /\.scheduled-editor-section > h3 \{/);
  assert.doesNotMatch(css, /\.scheduled-editor fieldset/);
});

test("New task, Skills, and Scheduled tasks share one compact peer menu", async () => {
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
      navigation.indexOf('t("scheduled.title")'),
  );
  assert.equal(
    (navigation.match(/className="sidebar-capability focus-ring"/g) ?? [])
      .length,
    3,
  );
  for (const icon of ["new-task", "skills", "scheduled-tasks"])
    assert.match(navigation, new RegExp(`<Icon name="${icon}"`));
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
    expectedExecutionGeneration: "3",
    input: { kind: "text", text: "Summarize" },
    recurrence: { kind: "once", atUnixSeconds: "1800000000" },
  };
  assert.equal(
    (await client.createScheduledTask(mutation)).scheduledTaskId,
    "8",
  );
  await client.setScheduledTaskEnabled("8", "1", false);
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
    enabled: false,
  });
});
