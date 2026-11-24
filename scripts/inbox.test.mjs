import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  NodeFilter: dom.window.NodeFilter,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  MutationObserver: dom.window.MutationObserver,
  CustomEvent: dom.window.CustomEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

if (!HTMLElement.prototype.hasPointerCapture)
  HTMLElement.prototype.hasPointerCapture = () => false;
if (!HTMLElement.prototype.setPointerCapture)
  HTMLElement.prototype.setPointerCapture = () => undefined;
if (!HTMLElement.prototype.releasePointerCapture)
  HTMLElement.prototype.releasePointerCapture = () => undefined;

const { cleanup, render, screen, waitFor } =
  await import("./renderer-testing-library.mjs");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const inboxModule = await vite.ssrLoadModule(
  "/src/features/inbox/MessageInbox.tsx",
);
const { decodeInboxView } = await vite.ssrLoadModule(
  "/src/bridge/decode-contracts.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const {
  InboxMain,
  InboxSidebar,
  MessageNavigationItem,
  inboxUnread,
  useInbox,
} = inboxModule;

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const at = (iso) => String(Date.parse(iso));

function view(patch = {}) {
  return decodeInboxView({
    binding: "1",
    state: "ready",
    accountScope: null,
    unreadTotal: "3",
    syncedAtMs: at("2026-11-23T08:00:00Z"),
    conversations: [
      {
        peerId: "ann",
        username: "ann_u",
        name: "Ann",
        unread: "2",
        latest: {
          id: "12",
          direction: "in",
          preview: "Can you review?",
          sentAtMs: at("2026-11-23T08:00:00Z"),
        },
        lastAtMs: at("2026-11-23T08:00:00Z"),
      },
      {
        peerId: "bob",
        username: "bob_u",
        name: "Bob",
        unread: "0",
        latest: {
          id: "9",
          direction: "out",
          preview: "Done",
          sentAtMs: at("2026-11-22T08:00:00Z"),
        },
        lastAtMs: null,
      },
    ],
    conversationsLoaded: true,
    loadingConversations: false,
    hasEarlier: false,
    diagnostic: null,
    ...patch,
  });
}

function message(id, direction, text, taskIds = []) {
  return {
    id,
    direction,
    fromPeerId: direction === "in" ? "ann" : "me",
    fromName: direction === "in" ? "Ann" : "Me",
    fromAgent: null,
    isNew: false,
    recipients:
      direction === "in"
        ? []
        : [{ peerId: "ann", name: "Ann", read: false, readAtMs: null }],
    text,
    truncated: false,
    sentAtMs: at("2026-11-23T07:00:00Z"),
    taskIds,
  };
}

function taskView(patch = {}) {
  return {
    id: "13066",
    name: "Inbox",
    progress: "doing",
    state: null,
    path: "metawork / Inbox",
    description: "Read only",
    assignees: ["Ann"],
    createdBy: null,
    updatedAtMs: null,
    canLink: false,
    lastNote: null,
    notes: [],
    children: [],
    ...patch,
  };
}

function fakeClient({
  pages = {},
  task,
  taskState,
  details = {},
  fileState = "opened",
  sendStates = [],
  sendGate = null,
  people = [],
  conversation = null,
} = {}) {
  const calls = [];
  return {
    calls,
    async sendInboxMessage(binding, to, text, requestKey) {
      calls.push([
        "send",
        binding,
        to.peerId ?? `@${to.username}`,
        text,
        requestKey,
      ]);
      if (sendGate) await sendGate;
      const state = sendStates.shift() ?? "sent";
      return {
        binding,
        requestId: String(calls.length),
        state,
        sent: state === "sent" ? ["Ann"] : [],
        conversation: state === "sent" ? conversation : null,
      };
    },
    async listInboxPeople(binding) {
      calls.push(["people", binding]);
      return {
        binding,
        requestId: String(calls.length),
        state: "ready",
        people,
      };
    },
    async openInboxFile(binding, fileId) {
      calls.push(["file", binding, fileId]);
      return { binding, requestId: String(calls.length), state: fileState };
    },
    async refreshInbox(binding, explicit) {
      calls.push(["refresh", binding, explicit]);
      return { outcome: "accepted" };
    },
    async loadEarlierInbox(binding) {
      calls.push(["earlier", binding]);
      return { outcome: "accepted" };
    },
    async readInboxConversation(binding, target, page, anchorId) {
      const peerId =
        typeof target === "string" ? target : "@" + target.username;
      calls.push(["read", binding, peerId, page, anchorId]);
      const answer = pages[`${peerId}:${page}:${anchorId}`] ??
        (page === "refresh" ? pages[`${peerId}:latest:null`] : undefined) ?? {
          messages: [],
        };
      return {
        binding,
        requestId: String(calls.length),
        state: "ready",
        peerId,
        hasEarlier: false,
        complete: true,
        ...answer,
      };
    },
    async readInboxTask(binding, taskId) {
      calls.push(["task", binding, taskId]);
      const detail = details[taskId] ?? (task ? { task } : null);
      return {
        binding,
        requestId: String(calls.length),
        state: detail ? "ready" : (taskState ?? "failed"),
        task: null,
        file: null,
        project: null,
        ...detail,
      };
    },
  };
}

function Harness({ client, inbox, open, onOpenConnectors }) {
  const controller = useInbox(client, inbox, open, false);
  return createElement(
    "div",
    null,
    createElement(MessageNavigationItem, {
      active: open,
      unread: inboxUnread(inbox),
      onOpen() {},
    }),
    createElement(InboxSidebar, { inbox, controller }),
    createElement(InboxMain, { inbox, controller, onOpenConnectors }),
  );
}

function element(client, inbox, { open = true, onOpenConnectors } = {}) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(Harness, {
      client,
      inbox,
      open,
      onOpenConnectors: onOpenConnectors ?? (() => {}),
    }),
  );
}

test("the navigation badge shows the unread total only from a usable connection", async () => {
  const client = fakeClient();
  const { rerender } = render(element(client, view()));
  assert.ok(screen.getByRole("button", { name: "Messages, 3 unread" }));
  const rows = view().conversations;
  const oneLeft = rows.map((row) => ({
    ...row,
    unread: row.peerId === "bob" ? "1" : "0",
  }));
  rerender(element(client, view({ unreadTotal: "1", conversations: oneLeft })));
  assert.equal(
    document.querySelector(".primary-navigation-unread").textContent,
    "1",
  );
  assert.equal(
    screen
      .getByRole("button", { name: "Ann" })
      .querySelector(".inbox-unread-badge"),
    null,
  );
  assert.equal(
    document.querySelector(".inbox-list-row[data-unread=true] strong")
      .textContent,
    "Bob",
  );
  rerender(
    element(
      client,
      view({
        unreadTotal: "0",
        conversations: rows.map((row) => ({ ...row, unread: "0" })),
      }),
    ),
  );
  assert.equal(document.querySelector(".inbox-unread-badge"), null);
  rerender(
    element(
      client,
      view({ state: "reauthorize", unreadTotal: null, diagnostic: null }),
    ),
  );
  assert.ok(screen.getByRole("button", { name: "Messages" }));
  assert.equal(document.querySelector(".primary-navigation-unread"), null);
});

test("each connection state says what is wrong and what can be done", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient();
  let connectors = 0;
  const { rerender } = render(
    element(
      client,
      view({ state: "unavailable", unreadTotal: null, conversations: [] }),
      { onOpenConnectors: () => connectors++ },
    ),
  );
  assert.ok(screen.getByText("MetaTeam messaging is not connected"));
  await user.click(screen.getByRole("button", { name: "Open connectors" }));
  assert.equal(connectors, 1);

  rerender(
    element(
      client,
      view({ state: "checking", unreadTotal: null, conversations: [] }),
    ),
  );
  assert.ok(screen.getByText("Connecting to MetaTeam…"));

  rerender(
    element(
      client,
      view({ state: "reauthorize", unreadTotal: null, conversations: [] }),
    ),
  );
  assert.ok(screen.getByText("Reconnect MetaTeam or confirm this device"));
  const before = client.calls.filter(([kind]) => kind === "refresh").length;
  await user.click(screen.getByRole("button", { name: "Retry" }));
  // Retry is the user's own: it passes the background rules.
  assert.equal(
    client.calls.filter(([kind]) => kind === "refresh").length,
    before + 1,
  );
  assert.deepEqual(client.calls.at(-1), ["refresh", "1", true]);

  rerender(
    element(
      client,
      view({
        state: "unreachable",
        unreadTotal: null,
        conversations: [],
        syncedAtMs: null,
        diagnostic: {
          phase: "connect",
          cause: "connect_failed",
          elapsed: "under_1s",
        },
      }),
    ),
  );
  assert.ok(screen.getByText("MetaTeam messages can't be read right now"));
  assert.ok(screen.getByText("Request details"));

  // With earlier data the list stays and a banner says how old it is.
  rerender(element(client, view({ state: "unreachable" })));
  assert.match(
    document.querySelector(".inbox-banner").textContent,
    /Showing what was read at/,
  );
  assert.ok(screen.getByRole("button", { name: "Ann, 2 unread" }));
});

test("the open inbox refreshes, and a conversation is read only when it is opened", async (t) => {
  const timer = t.mock.method(window, "setInterval");
  const user = userEvent.setup({ document });
  const client = fakeClient({
    pages: {
      "ann:latest:null": {
        hasEarlier: true,
        messages: [
          message("10", "out", "Please look", ["13066"]),
          message("12", "in", "Can you review?"),
        ],
      },
      "ann:before:10": { messages: [message("4", "in", "Earlier note")] },
    },
    task: taskView(),
  });
  const closed = render(element(client, view(), { open: false }));
  assert.equal(client.calls.length, 0);
  assert.equal(timer.mock.callCount(), 0);
  closed.unmount();

  render(element(client, view()));
  assert.equal(timer.mock.calls[0].arguments[1], 10_000);
  // The page's own refresh is automatic, so the Host keeps its rules.
  await waitFor(() =>
    assert.deepEqual(
      client.calls.find(([kind]) => kind === "refresh"),
      ["refresh", "1", false],
    ),
  );
  assert.ok(screen.getByText("You: Done"));
  assert.ok(screen.getByText("Select a member"));
  assert.equal(client.calls.filter(([kind]) => kind === "read").length, 0);

  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() => assert.ok(screen.getByText("Please look")));
  assert.deepEqual(
    client.calls.find(([kind]) => kind === "read"),
    ["read", "1", "ann", "latest", null],
  );

  await user.click(
    screen.getByRole("button", { name: "Load earlier messages" }),
  );
  await waitFor(() => assert.ok(screen.getByText("Earlier note")));
  assert.ok(
    client.calls.some(
      (call) => call[0] === "read" && call[3] === "before" && call[4] === "10",
    ),
  );

  await user.click(screen.getByRole("button", { name: /#13066/ }));
  await waitFor(() => assert.ok(screen.getByText("Read only")));
  assert.ok(
    screen.getByText("metawork / #13066 · In progress · Assigned to Ann"),
  );
  const more = screen.getByText("More information");
  assert.equal(more.parentElement.open, false);
  await user.click(more);
  assert.ok(screen.getByText("metawork / Inbox"));
  assert.deepEqual(
    client.calls.find(([kind]) => kind === "task"),
    ["task", "1", "13066"],
  );
});

test("the timer follows only the open conversation even with zero unread, and a new connection starts over", async (t) => {
  const timer = t.mock.method(window, "setInterval");
  const user = userEvent.setup({ document });
  const client = fakeClient({
    pages: {
      "ann:latest:null": { messages: [message("12", "in", "Can you review?")] },
      "ann:after:12": { messages: [message("15", "in", "Any update?")] },
    },
  });
  const initial = view();
  initial.conversations[0] = { ...initial.conversations[0], latest: null };
  const { rerender } = render(element(client, initial));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 1),
  );

  rerender(element(client, { ...initial, unreadTotal: "0" }));
  await timer.mock.calls[0].arguments[0]();
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 2),
  );
  assert.ok(
    client.calls.some(
      (call) => call[0] === "read" && call[3] === "after" && call[4] === "12",
    ),
  );

  rerender(element(client, view({ binding: "2" })));
  await waitFor(() => assert.ok(screen.getByText("Select a member")));
});

test("reopening a saved conversation refreshes receipts even when there are no new message ids", async () => {
  const user = userEvent.setup({ document });
  const sent = message("12", "out", "Delivered yesterday");
  const confirmed = {
    ...sent,
    recipients: [
      {
        peerId: "ann",
        name: "Ann",
        read: true,
        readAtMs: at("2026-11-23T08:00:00Z"),
      },
    ],
  };
  const client = fakeClient({
    pages: {
      "ann:latest:null": { messages: [sent] },
      "ann:refresh:null": { messages: [confirmed] },
    },
  });
  render(element(client, view()));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(
      document.querySelector(".inbox-message-receipt")?.dataset.read,
      "true",
    ),
  );
  assert.deepEqual(
    client.calls
      .filter(([kind]) => kind === "read")
      .map((call) => call.slice(2)),
    [
      ["ann", "latest", null],
      ["ann", "refresh", null],
    ],
  );
  assert.equal(screen.getAllByText("Delivered yesterday").length, 1);
});

test("the conversation list asks for earlier conversations at its end", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient();
  render(element(client, view({ hasEarlier: true })));
  await user.click(
    screen.getByRole("button", { name: "Load earlier conversations" }),
  );
  assert.ok(client.calls.some(([kind]) => kind === "earlier"));
  cleanup();
  render(
    element(
      client,
      view({ conversations: [], conversationsLoaded: false, unreadTotal: "0" }),
    ),
  );
  assert.ok(screen.getByText("Loading conversations…"));
});

test("what the user sent to themself is the Me conversation", async () => {
  const user = userEvent.setup({ document });
  const note = {
    ...message("20", "self", "Remember the demo"),
    fromPeerId: "u-me",
    recipients: [],
  };
  const client = fakeClient({
    pages: { "me:latest:null": { messages: [note] } },
  });
  render(
    element(
      client,
      view({
        conversations: [
          {
            peerId: "me",
            username: "zj",
            name: "Zhu",
            unread: "0",
            latest: {
              id: "20",
              direction: "self",
              preview: "Remember the demo",
              sentAtMs: at("2026-11-23T09:00:00Z"),
            },
            lastAtMs: null,
          },
        ],
      }),
    ),
  );
  assert.ok(screen.getByText("You: Remember the demo"));
  await user.click(screen.getByRole("button", { name: "Me" }));
  await waitFor(() => assert.ok(screen.getByRole("heading", { name: "Me" })));
  assert.deepEqual(
    client.calls.find(([kind]) => kind === "read"),
    ["read", "1", "me", "latest", null],
  );
  await waitFor(() =>
    assert.equal(
      document.querySelector(".inbox-message").dataset.direction,
      "outgoing",
    ),
  );
});

test("messages show new marks, sending agents and read receipts; unread rows show their time", async () => {
  const user = userEvent.setup({ document });
  const group = {
    ...message("30", "out", "Shipped"),
    recipients: [
      {
        peerId: "ann",
        name: "Ann",
        read: true,
        readAtMs: at("2026-11-23T07:30:00Z"),
      },
      { peerId: "bob", name: "Bob", read: false, readAtMs: null },
    ],
  };
  const client = fakeClient({
    pages: {
      "ann:latest:null": {
        messages: [
          { ...message("31", "in", "From my agent"), isNew: true },
          {
            ...message("32", "in", "Automated"),
            fromAgent: "claude-code@box",
          },
          message("33", "out", "Thanks"),
          group,
        ],
      },
    },
  });
  const base = view();
  render(
    element(
      client,
      view({
        conversations: [
          ...base.conversations,
          {
            peerId: "cy",
            username: null,
            name: "Cy",
            unread: "1",
            latest: null,
            lastAtMs: at("2026-11-20T10:00:00Z"),
          },
        ],
      }),
    ),
  );
  const cy = screen.getByRole("button", { name: "Cy, 1 unread" });
  assert.equal(
    cy.querySelector("time").getAttribute("datetime"),
    "2026-11-20T10:00:00.000Z",
  );
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() => assert.ok(screen.getByText("Shipped")));
  assert.equal(document.querySelectorAll(".inbox-new-badge").length, 1);
  assert.ok(screen.getByText("Sent by claude-code@box"));
  // One recipient: one status. A group: every recipient by name.
  assert.equal(
    document.querySelector(".inbox-message-receipt").textContent,
    "Unread",
  );
  const receipts = screen.getByRole("list", { name: "Read status" });
  assert.deepEqual(
    [...receipts.querySelectorAll("li")].map((item) => item.textContent),
    ["Ann: Read", "Bob: Unread"],
  );
});

test("a linked file, project or task shows its own details, opens nested items and downloads through the Host", async () => {
  const user = userEvent.setup({ document });
  const file = {
    id: "9830",
    name: "metawork-api.md",
    tag: "API",
    sizeBytes: "12034",
    mime: "text/markdown",
    description: null,
    by: "Lin",
    updatedAtMs: at("2026-11-21T03:00:00Z"),
    path: "space / metawork-api.md",
    content: "# MetaTeam messages",
    contentTruncated: false,
    downloadable: true,
  };
  const client = fakeClient({
    pages: {
      "ann:latest:null": {
        messages: [message("12", "in", "See these", ["740", "9749"])],
      },
    },
    details: {
      740: {
        project: {
          id: "740",
          name: "metawork",
          description: "Desktop app",
          path: null,
          updatedAtMs: null,
          files: [
            {
              id: "9830",
              name: "metawork-api.md",
              tag: "API",
              sizeBytes: "12034",
              mime: "text/markdown",
              by: "Lin",
              updatedAtMs: null,
            },
          ],
          filesTruncated: false,
          fileTags: [{ tag: "API", count: "1" }],
        },
      },
      9830: { file },
      9749: {
        task: taskView({
          id: "9749",
          name: "Open API",
          path: "metawork / Open API",
          state: "closed",
          createdBy: "Lin",
          lastNote: { text: "Deployed", atMs: null, by: "Lin" },
          notes: [
            { text: "Found it", atMs: null, by: "Lin" },
            { text: "Deployed", atMs: null, by: "Lin" },
          ],
          children: [{ id: "9801", name: "Write docs", progress: "todo" }],
        }),
      },
      9801: { task: taskView({ id: "9801", name: "Write docs" }) },
    },
  });
  render(element(client, view()));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  const body = await screen.findByText("See these");
  const card = body.closest(".inbox-bubble");
  const projectLink = screen.getByRole("button", { name: /#740/ });
  assert.ok(card?.contains(projectLink));
  const taskLink = screen.getByRole("button", { name: /#9749/ });
  assert.ok(card.contains(taskLink));
  await user.click(body);
  assert.equal(
    client.calls.some(([kind]) => kind === "task"),
    false,
  );

  taskLink.focus();
  await user.tab({ shift: true });
  assert.equal(document.activeElement, projectLink);
  await user.keyboard("{Enter}");
  await waitFor(() => assert.ok(screen.getByText("Desktop app")));
  assert.ok(screen.getByText("API · 1"));
  await user.click(screen.getByRole("button", { name: /metawork-api\.md/ }));
  await waitFor(() => assert.ok(screen.getByText("# MetaTeam messages")));
  assert.ok(screen.getByText("13 KB"));
  assert.ok(screen.getByText("text/markdown"));
  assert.ok(screen.getByText("space / metawork-api.md"));
  await user.click(screen.getByRole("button", { name: "Download" }));
  await waitFor(() => assert.ok(screen.getByText("Opened in your browser.")));
  assert.deepEqual(client.calls.at(-1), ["file", "1", "9830"]);
  // Back to the project the file was opened from.
  await user.click(screen.getByRole("button", { name: "Back" }));
  await waitFor(() => assert.ok(screen.getByText("Desktop app")));
  await user.keyboard("{Escape}");

  await user.click(screen.getByRole("button", { name: /#9749/ }));
  await screen.findByText("Latest note");
  assert.ok(screen.getByText(/#9749 .* Closed .* Ann/));
  assert.equal(screen.getAllByText("Deployed").length, 1);
  const history = screen.getByText("Earlier notes (1)");
  assert.equal(history.parentElement.open, false);
  await user.click(history);
  assert.ok(history.parentElement.contains(screen.getByText("Found it")));
  await user.click(screen.getByText("Sub-tasks (1)"));
  await user.click(screen.getByRole("button", { name: /Write docs/ }));
  await waitFor(() =>
    assert.ok(screen.getByRole("heading", { name: "Write docs" })),
  );
  assert.deepEqual(client.calls.at(-1), ["task", "1", "9801"]);
});

test("a reply is sent once, shown from the newer messages, and retried under the same request key", async () => {
  const user = userEvent.setup({ document });
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const client = fakeClient({
    sendGate: gate,
    sendStates: ["failed", "sent"],
    pages: {
      "ann:latest:null": { messages: [message("12", "in", "Can you review?")] },
      "ann:after:12": { messages: [message("13", "out", "Looking now")] },
    },
  });
  const initial = view();
  initial.conversations[0] = { ...initial.conversations[0], latest: null };
  render(element(client, initial));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 1),
  );
  const box = screen.getByRole("textbox", { name: "Message Ann" });
  const sendButton = screen.getByRole("button", { name: "Send" });
  assert.equal(sendButton.disabled, true);
  // Shift+Enter is a new line; Enter sends.
  await user.type(box, "Looking{Shift>}{Enter}{/Shift}now");
  assert.equal(box.value, "Looking\nnow");
  await user.clear(box);
  await user.type(box, "Looking now{Enter}");
  await waitFor(() =>
    assert.ok(screen.getByRole("button", { name: "Sending…" })),
  );
  // The task composer's shell: one box, the round send button in it.
  const shell = box.closest(".ai-composer");
  assert.equal(shell.dataset.state, "running");
  assert.ok(shell.querySelector("button.composer-send"));
  assert.equal(box.placeholder, "Write a message…");
  // While it is on its way nothing else is submitted.
  assert.equal(box.readOnly, true);
  await user.type(box, "{Enter}");
  assert.equal(client.calls.filter(([kind]) => kind === "send").length, 1);
  release();
  await waitFor(() =>
    assert.ok(screen.getByText(/Retrying won't send it twice/)),
  );
  const first = client.calls.find(([kind]) => kind === "send");
  assert.deepEqual(first.slice(0, 4), ["send", "1", "ann", "Looking now"]);
  assert.match(
    first[4],
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  assert.equal(box.value, "Looking now");

  await user.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => assert.ok(screen.getByText("Looking now")));
  const sends = client.calls.filter(([kind]) => kind === "send");
  assert.equal(sends.length, 2);
  assert.equal(sends[1][4], first[4]);
  // Sent: the box empties and the newer messages are read.
  assert.equal(box.value, "");
  assert.ok(
    client.calls.some(
      (call) => call[0] === "read" && call[3] === "after" && call[4] === "12",
    ),
  );
  assert.equal(document.querySelector(".inbox-composer-failure"), null);
});

test("a refused reply is not retried as is; a changed message gets a new request key", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient({
    sendStates: ["rejected", "sent"],
    pages: {
      "ann:latest:null": { messages: [message("12", "in", "Can you review?")] },
    },
  });
  render(element(client, view()));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 1),
  );
  const box = screen.getByRole("textbox", { name: "Message Ann" });
  await user.type(box, "Hi");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() =>
    assert.ok(
      screen.getByText(
        "MetaTeam refused this message. Change it to send again.",
      ),
    ),
  );
  assert.equal(screen.queryByRole("button", { name: "Retry" }), null);
  await user.type(box, "!");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(box.value, ""));
  const sends = client.calls.filter(([kind]) => kind === "send");
  assert.equal(sends.length, 2);
  assert.equal(sends[1][3], "Hi!");
  assert.notEqual(sends[1][4], sends[0][4]);
});

test("the searchable directory keeps recent conversations first and opens an empty chat in the same pane", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient({
    people: [
      { username: "cy", name: "Cy", online: null },
      { username: "ann_u", name: "Ann", online: true },
      { username: "alex", name: "Alex", online: false },
    ],
    sendStates: ["failed", "sent"],
    conversation: { peerId: "alex-id", name: "Alex" },
    pages: {
      "alex-id:refresh:null": {
        messages: [message("40", "out", "Hello Alex")],
      },
    },
  });
  const { rerender } = render(element(client, view()));
  const names = () =>
    Array.from(
      document.querySelectorAll(".inbox-list-row strong"),
      (el) => el.textContent,
    );
  await waitFor(() => assert.deepEqual(names(), ["Ann", "Bob", "Alex", "Cy"]));
  assert.equal(screen.queryByRole("dialog"), null);
  const search = screen.getByRole("searchbox", { name: "Search members" });
  await user.type(search, "ANN_U");
  assert.deepEqual(names(), ["Ann"]);
  await user.clear(search);
  await user.type(search, "unmatched");
  assert.ok(screen.getByText("No matching members."));
  await user.clear(search);
  assert.equal(client.calls.filter(([kind]) => kind === "read").length, 0);
  await user.click(screen.getByRole("button", { name: "Alex" }));
  assert.deepEqual(
    client.calls.filter(([kind]) => kind === "read"),
    [["read", "1", "@alex", "latest", null]],
  );
  assert.deepEqual(names(), ["Ann", "Bob", "Alex", "Cy"]);
  assert.equal(document.querySelectorAll(".inbox-bubble").length, 0);
  await user.type(
    screen.getByRole("textbox", { name: "Message Alex" }),
    "Hello Alex{Enter}",
  );
  await user.click(await screen.findByRole("button", { name: "Retry" }));
  await screen.findByText("Hello Alex");
  const sends = client.calls.filter(([kind]) => kind === "send");
  assert.equal(sends.length, 2);
  assert.deepEqual(sends[0].slice(0, 4), ["send", "1", "@alex", "Hello Alex"]);
  assert.equal(sends[1][4], sends[0][4]);
  const next = view();
  next.conversations.unshift({
    ...next.conversations[0],
    peerId: "alex-id",
    username: "alex",
    name: "Alex",
    unread: "0",
  });
  rerender(element(client, next));
  assert.deepEqual(names(), ["Alex", "Ann", "Bob", "Cy"]);
  assert.equal(
    screen.getByRole("button", { name: "Alex" }).getAttribute("aria-current"),
    "true",
  );
  assert.equal(client.calls.filter(([kind]) => kind === "people").length, 1);
});

test("a directory member with remote history resolves to their own conversation before replying", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient({
    people: [{ username: "ann2", name: "Ann", online: false }],
    pages: {
      "@ann2:latest:null": {
        peerId: "42",
        messages: [message("41", "in", "Older exchange")],
      },
    },
  });
  render(element(client, view()));
  await user.type(screen.getByRole("searchbox"), "ann2");
  await user.click(screen.getByRole("button", { name: "Ann @ann2" }));
  await screen.findByText("Older exchange");
  await user.type(
    screen.getByRole("textbox", { name: "Message Ann" }),
    "Reply{Enter}",
  );
  assert.deepEqual(
    client.calls.filter(([kind]) => kind === "send")[0].slice(0, 4),
    ["send", "1", "42", "Reply"],
  );
  assert.deepEqual(client.calls.filter(([kind]) => kind === "read").at(-1), [
    "read",
    "1",
    "42",
    "after",
    "41",
  ]);
});

test("leaving a conversation while it sends keeps its reply box, and the answer lands only in that attempt", async () => {
  const user = userEvent.setup({ document });
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const client = fakeClient({
    sendGate: gate,
    sendStates: ["failed", "sent"],
    pages: {
      "ann:latest:null": { messages: [message("12", "in", "Can you review?")] },
      "bob:latest:null": { messages: [message("9", "out", "Done")] },
    },
  });
  render(element(client, view()));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 1),
  );
  await user.type(screen.getByRole("textbox", { name: "Message Ann" }), "A");
  await user.keyboard("{Enter}");
  await waitFor(() =>
    assert.ok(screen.getByRole("button", { name: "Sending…" })),
  );

  // Bob's box is his own; one message is on its way, so his waits.
  await user.click(screen.getByRole("button", { name: "Bob" }));
  const bobBox = await screen.findByRole("textbox", { name: "Message Bob" });
  assert.equal(bobBox.value, "");
  await user.type(bobBox, "B{Enter}");
  await waitFor(() =>
    assert.ok(screen.getByText("Another message is still being sent.")),
  );
  assert.equal(client.calls.filter(([kind]) => kind === "send").length, 1);

  // Back with Ann: still her message, still on its way.
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  const annBox = await screen.findByRole("textbox", { name: "Message Ann" });
  assert.equal(annBox.value, "A");
  assert.equal(annBox.readOnly, true);
  release();
  await waitFor(() =>
    assert.ok(screen.getByText(/Retrying won't send it twice/)),
  );
  await user.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => assert.equal(annBox.value, ""));
  const sends = client.calls.filter(([kind]) => kind === "send");
  assert.equal(sends.length, 2);
  assert.deepEqual(sends[1].slice(2, 5), ["ann", "A", sends[0][4]]);
  // Bob's draft was never touched by Ann's answers.
  await user.click(screen.getByRole("button", { name: "Bob" }));
  assert.equal(
    (await screen.findByRole("textbox", { name: "Message Bob" })).value,
    "B",
  );
});

test("switching connections drops the selected member and ignores a late send answer", async () => {
  const user = userEvent.setup({ document });
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const client = fakeClient({
    sendGate: gate,
    people: [{ username: "bob", name: "Bob Li", online: null }],
    conversation: { peerId: "bob-id", name: "Bob Li" },
  });
  const { rerender } = render(element(client, view()));
  await user.click(await screen.findByRole("button", { name: /Bob Li/ }));
  await user.type(
    screen.getByRole("textbox", { name: "Message Bob Li" }),
    "Hi",
  );
  await user.click(screen.getByRole("button", { name: "Send" }));
  rerender(element(client, view({ binding: "2" })));
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  release();
  await waitFor(() =>
    assert.equal(client.calls.filter(([kind]) => kind === "send").length, 1),
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(screen.getByText("Select a member"));
  assert.deepEqual(
    client.calls.filter(([kind]) => kind === "read"),
    [["read", "1", "@bob", "latest", null]],
  );
});

test("a namesake remains searchable and the existing Me history has its own recipient", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient({
    people: [{ username: "colleague", name: "Zhu", online: true }],
  });
  const inbox = view();
  inbox.conversations = [
    {
      ...inbox.conversations[0],
      peerId: "me",
      name: "Zhu",
      username: "my_account",
      unread: "0",
    },
  ];
  render(element(client, inbox));
  await user.type(screen.getByRole("searchbox"), "colleague");
  assert.ok(await screen.findByRole("button", { name: "Zhu" }));
  assert.equal(screen.queryByRole("button", { name: "Me" }), null);
  await user.clear(screen.getByRole("searchbox"));
  await user.click(screen.getByRole("button", { name: "Me" }));
  await user.type(screen.getByRole("textbox", { name: "Message Me" }), "note");
  await user.click(screen.getByRole("button", { name: "Send" }));
  assert.deepEqual(client.calls.find(([kind]) => kind === "send").slice(1, 4), [
    "1",
    "me",
    "note",
  ]);
});

test("a refused task or a missing conversation is shown where it was asked for", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient({
    taskState: "forbidden",
    pages: {
      "ann:latest:null": {
        messages: [message("12", "in", "See the task", ["13066"])],
      },
      "bob:latest:null": { state: "not_found", messages: [] },
    },
  });
  render(element(client, view()));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 1),
  );
  await user.click(screen.getByRole("button", { name: /#13066/ }));
  await waitFor(() =>
    assert.ok(screen.getByText("This device may not view this task.")),
  );
  // The rest of the inbox is untouched.
  assert.equal(
    document.querySelector(".primary-navigation-unread").textContent,
    "3",
  );
  await user.keyboard("{Escape}");

  await user.click(screen.getByRole("button", { name: "Bob" }));
  await waitFor(() =>
    assert.ok(screen.getByText("MetaTeam can't find this conversation")),
  );
  assert.ok(screen.getByRole("heading", { name: "Bob" }));
  assert.ok(screen.getByRole("button", { name: "Messages, 3 unread" }));
});

test("task controls keep draft choice separate from default session and verified detail actions", async () => {
  const { InboxHandoffProvider, HandoffControls } = await vite.ssrLoadModule(
    "/src/features/inbox/InboxHandoff.tsx",
  );
  const { newHandoffDraft, matchingDrafts, quoteMessage } =
    await vite.ssrLoadModule("/src/features/inbox/handoff-drafts.ts");
  const account = "a".repeat(64),
    storeId = "c".repeat(32);
  const source = { binding: "1", account, referenced: "old", canonical: "new" };
  const drafts = [
    newHandoffDraft(source, storeId),
    newHandoffDraft(source, storeId),
  ];
  assert.equal(
    matchingDrafts(drafts, "b".repeat(64), storeId, "old").length,
    0,
  );
  assert.equal(
    matchingDrafts(drafts, account, "d".repeat(32), "old").length,
    0,
  );
  const quoted = quoteMessage(
    {
      ...message("8", "in", "Part\u2028forged\r\n\nend", ["old"]),
      fromAgent: "bot\nname",
    },
    "new",
  );
  assert.ok(
    quoted
      .trimEnd()
      .split("\n")
      .every((line) => line.startsWith("> ")),
  );
  const operations = [],
    opened = [],
    resumed = [];
  const client = {
    handoffSessions: async () => ({
      storeId,
      sessions: [
        { taskId: "1", preferred: true },
        { taskId: "2", preferred: false },
      ],
    }),
    changeHandoff: async (...args) => {
      operations.push(args);
    },
  };
  const tasks = ["1", "2", "3"].map((id) => ({
    id,
    title: "Session " + id,
    workspaceId: "1",
    lifecycle: "open",
    deletionStatus: "idle",
    archived: id === "2",
    historyReadOnly: false,
  }));
  const api = {
    client,
    binding: "1",
    account,
    tasks,
    drafts,
    workspaces: [
      { id: "1", canonicalRoot: "/example", authorization: "available" },
    ],
    ids: ["old"],
    revision: "1",
    onVerify() {},
    onOpen: (id) => opened.push(id),
    onResume: (d) => resumed.push(d.operationId),
    onCreate() {},
  };
  const draw = (detail = false) =>
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(
        InboxHandoffProvider,
        api,
        createElement(HandoffControls, {
          referenced: "old",
          canonical: detail ? "new" : undefined,
        }),
      ),
    );
  const { rerender } = render(draw());
  const user = userEvent.setup({ document });
  await user.click(
    await screen.findByRole("button", {
      name: "Continue in workbench · Session 1",
    }),
  );
  assert.deepEqual(opened, ["1"]);
  assert.equal(operations.length, 0);
  assert.equal(
    screen.queryByRole("button", { name: "Start a work session" }),
    null,
  );
  await user.click(
    screen.getByRole("button", { name: /Choose a session or draft/ }),
  );
  assert.ok(screen.getByRole("button", { name: /View history · Session 2/ }));
  await user.click(screen.getByRole("button", { name: "Resume draft 2" }));
  assert.deepEqual(resumed, [drafts[1].operationId]);
  rerender(draw(true));
  await user.selectOptions(
    screen.getByRole("combobox", { name: "Link session" }),
    "3",
  );
  await user.click(screen.getByRole("button", { name: "Link session" }));
  await waitFor(() =>
    assert.deepEqual(operations, [[source, storeId, "link", "3"]]),
  );
});
