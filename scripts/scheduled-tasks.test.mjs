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
      target: { kind: "default" },
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
  assert.match(html, /Runs in background/);
  assert.match(html, /Search scheduled tasks/);
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
  assert.match(html, /Try your own task/);
  assert.doesNotMatch(html, /Nothing is scheduled/);
});

test("Text schedules default to a managed workspace without requiring a user Workspace", async () => {
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

  fireEvent.click(screen.getByRole("button", { name: "New schedule" }));
  assert.ok(screen.getByRole("dialog", { name: "Schedule editor" }));
  assert.equal(screen.getByRole("button", { name: "Skill" }).disabled, true);
  assert.equal(screen.getByLabelText("Run files").value, "default");
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Independent brief" },
  });
  fireEvent.change(
    screen.getByPlaceholderText(/Describe what MetaWork should do/),
    { target: { value: "Summarize current work" } },
  );
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.ok(created));
  assert.deepEqual(created.target, { kind: "default" });
  assert.equal("workspaceId" in created, false);
  assert.equal(created.input.kind, "text");
});

test("Skill schedules force an explicit user Workspace target", () => {
  const snapshot = structuredClone(fixture);
  snapshot.capabilities.managedWorkspaces = true;
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  renderDom(scheduledElement(snapshot));

  fireEvent.click(screen.getByRole("button", { name: "New schedule" }));
  fireEvent.click(screen.getByRole("button", { name: "Skill" }));
  const target = screen.getByLabelText("Run files");
  assert.equal(target.value, "explicit");
  assert.equal(target.disabled, true);
  assert.equal(screen.getByLabelText("Workspace").value, "1");
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
    target: {
      kind: "explicit",
      workspaceId: "1",
      expectedWorkspaceEpoch: "2",
    },
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
