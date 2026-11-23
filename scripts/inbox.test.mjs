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
    unreadTotal: "3",
    syncedAtMs: at("2026-11-23T08:00:00Z"),
    conversations: [
      {
        peerId: "ann",
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

function fakeClient({ pages = {}, task, taskState } = {}) {
  const calls = [];
  return {
    calls,
    async refreshInbox(binding, explicit) {
      calls.push(["refresh", binding, explicit]);
      return { outcome: "accepted" };
    },
    async loadEarlierInbox(binding) {
      calls.push(["earlier", binding]);
      return { outcome: "accepted" };
    },
    async readInboxConversation(binding, peerId, page, anchorId) {
      calls.push(["read", binding, peerId, page, anchorId]);
      const answer = pages[`${peerId}:${page}:${anchorId}`] ?? {
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
      return {
        binding,
        requestId: String(calls.length),
        state: task ? "ready" : (taskState ?? "failed"),
        task: task ?? null,
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

test("the open inbox refreshes, and a conversation is read only when it is opened", async () => {
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
    task: {
      id: "13066",
      name: "Inbox",
      progress: "doing",
      state: null,
      path: "metawork / Inbox",
      description: "Read only",
      assignees: ["Ann"],
      updatedAtMs: null,
    },
  });
  const closed = render(element(client, view(), { open: false }));
  assert.equal(client.calls.length, 0);
  closed.unmount();

  render(element(client, view()));
  // The page's own refresh is automatic, so the Host keeps its rules.
  await waitFor(() =>
    assert.deepEqual(client.calls[0], ["refresh", "1", false]),
  );
  assert.ok(screen.getByText("You: Done"));
  assert.ok(screen.getByText("Select a conversation"));
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

  await user.click(screen.getByRole("button", { name: /Task #13066/ }));
  await waitFor(() => assert.ok(screen.getByText("Read only")));
  assert.ok(screen.getByText("doing"));
  assert.ok(screen.getByText("metawork / Inbox"));
  assert.deepEqual(
    client.calls.find(([kind]) => kind === "task"),
    ["task", "1", "13066"],
  );
});

test("an open conversation follows its newer messages and a new connection starts over", async () => {
  const user = userEvent.setup({ document });
  const client = fakeClient({
    pages: {
      "ann:latest:null": { messages: [message("12", "in", "Can you review?")] },
      "ann:after:12": { messages: [message("15", "in", "Any update?")] },
    },
  });
  const { rerender } = render(element(client, view()));
  await user.click(screen.getByRole("button", { name: "Ann, 2 unread" }));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 1),
  );

  const newer = view();
  const updated = view({
    conversations: [
      {
        ...newer.conversations[0],
        unread: "3",
        latest: {
          ...newer.conversations[0].latest,
          id: "15",
          preview: "Any update?",
        },
      },
      newer.conversations[1],
    ],
  });
  rerender(element(client, updated));
  await waitFor(() =>
    assert.equal(document.querySelectorAll(".inbox-bubble").length, 2),
  );
  assert.ok(
    client.calls.some(
      (call) => call[0] === "read" && call[3] === "after" && call[4] === "12",
    ),
  );

  rerender(element(client, view({ binding: "2" })));
  await waitFor(() => assert.ok(screen.getByText("Select a conversation")));
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
  await user.click(screen.getByRole("button", { name: /Task #13066/ }));
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
