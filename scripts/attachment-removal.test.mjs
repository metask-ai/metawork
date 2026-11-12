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
test.afterEach(() => {
  cleanup();
  window.sessionStorage.clear();
});
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const { AttachmentRemovalCoordinator } = await vite.ssrLoadModule(
  "/src/app/attachment-removal.ts",
);
const { useTaskDrafts, useNewTaskDrafts } = await vite.ssrLoadModule(
  "/src/features/composer/useTaskDrafts.ts",
);
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
};
const attachment = (letter) => ({
  token: letter.repeat(48),
  kind: "file",
  displayName: `${letter}.html`,
  sizeBytes: "3",
});

for (const [name, hook] of [
  ["Task", useTaskDrafts],
  ["New task", useNewTaskDrafts],
]) {
  test(`${name} removal preserves latest owned text, other attachments and switched drafts`, async () => {
    let drafts;
    function Harness({ id }) {
      drafts = hook(id);
      return null;
    }
    const view = render(createElement(Harness, { id: "one" }));
    act(() =>
      drafts.updateDraft({
        kind: "multimodal",
        text: "old",
        attachments: [attachment("a"), attachment("b")],
      }),
    );
    const release = deferred();
    const states = [];
    const removal = new AttachmentRemovalCoordinator((busy) =>
      states.push(busy),
    );
    removal.resetGeneration("1");
    let pending;
    act(() => {
      pending = removal.remove({
        generation: "1",
        targetId: "one",
        token: attachment("a").token,
        target: drafts,
        release: () => release.promise,
        recover: async () => assert.fail(),
        unconfirmed: () => assert.fail(),
      });
      assert.equal(removal.busy, true);
      assert.deepEqual(drafts.currentDraft("one").attachments, [
        attachment("b"),
      ]);
      drafts.updateDraft({
        ...drafts.currentDraft("one"),
        text: "edited",
        attachments: [attachment("b"), attachment("c")],
      });
    });
    view.rerender(createElement(Harness, { id: "two" }));
    act(() => drafts.updateDraft({ kind: "text", text: "second task" }));
    await act(async () => {
      release.resolve({ released: true });
      await pending;
    });
    assert.deepEqual(drafts.currentDraft("two"), {
      kind: "text",
      text: "second task",
    });
    view.rerender(createElement(Harness, { id: "one" }));
    assert.deepEqual(drafts.currentDraft("one"), {
      kind: "multimodal",
      text: "edited",
      attachments: [attachment("b"), attachment("c")],
    });
    assert.equal(removal.busy, false);
    assert.deepEqual(states, [false, true, false]);
  });
}

test("removal rejects stale targets and serializes repeated release until acknowledgement", async () => {
  let drafts;
  function Harness({ id }) {
    drafts = useTaskDrafts(id);
    return null;
  }
  const view = render(createElement(Harness, { id: "one" }));
  act(() =>
    drafts.updateDraft({
      kind: "multimodal",
      text: "instruction",
      attachments: [attachment("a"), attachment("b")],
    }),
  );
  const oldTarget = drafts;
  view.rerender(createElement(Harness, { id: "two" }));
  const removal = new AttachmentRemovalCoordinator(() => {});
  removal.resetGeneration("1");
  const gate = deferred();
  const calls = [];
  const request = {
    generation: "1",
    targetId: "one",
    token: attachment("a").token,
    target: oldTarget,
    release: (token) => {
      calls.push(token);
      return gate.promise;
    },
    recover: async () => assert.fail(),
    unconfirmed: () => assert.fail(),
  };
  await removal.remove(request);
  assert.deepEqual(calls, []);
  view.rerender(createElement(Harness, { id: "one" }));
  let pending;
  act(() => {
    pending = removal.remove(request);
  });
  await removal.remove({ ...request, token: attachment("b").token });
  assert.deepEqual(calls, [attachment("a").token]);
  await act(async () => {
    gate.resolve({ released: false });
    await pending;
  });
  assert.deepEqual(drafts.currentDraft("one").attachments, [attachment("b")]);
  await act(async () => {
    await removal.remove({ ...request, token: attachment("b").token });
  });
  assert.deepEqual(drafts.currentDraft("one"), {
    kind: "text",
    text: "instruction",
  });
});

test("old generation failure/finally neither recovers nor unlocks a new removal", async () => {
  let drafts;
  function Harness() {
    drafts = useTaskDrafts("one");
    return null;
  }
  render(createElement(Harness));
  act(() =>
    drafts.updateDraft({
      kind: "multimodal",
      text: "old",
      attachments: [attachment("a")],
    }),
  );
  const removal = new AttachmentRemovalCoordinator(() => {});
  removal.resetGeneration("1");
  const old = deferred(),
    fresh = deferred();
  const request = {
    generation: "1",
    targetId: "one",
    token: attachment("a").token,
    target: drafts,
    release: () => old.promise,
    recover: async () => assert.fail(),
    unconfirmed: () => assert.fail(),
  };
  let first, second;
  act(() => {
    first = removal.remove(request);
  });
  removal.resetGeneration("2");
  act(() => {
    drafts.updateDraft({
      kind: "multimodal",
      text: "fresh",
      attachments: [attachment("b")],
    });
    second = removal.remove({
      ...request,
      generation: "2",
      token: attachment("b").token,
      release: () => fresh.promise,
    });
  });
  old.reject(new Error("old CleanupFailed"));
  await first;
  assert.equal(removal.busy, true);
  await act(async () => {
    fresh.resolve({ released: true });
    await second;
  });
  assert.equal(removal.busy, false);
  assert.deepEqual(drafts.currentDraft("one"), { kind: "text", text: "fresh" });
});

test("disposed removal ignores a late rejection without publishing or recovering", async () => {
  let drafts;
  function Harness() {
    drafts = useTaskDrafts("one");
    return null;
  }
  render(createElement(Harness));
  act(() =>
    drafts.updateDraft({
      kind: "multimodal",
      text: "keep",
      attachments: [attachment("a")],
    }),
  );
  const states = [];
  const removal = new AttachmentRemovalCoordinator((busy) => states.push(busy));
  removal.resetGeneration("1");
  const gate = deferred();
  let pending;
  act(() => {
    pending = removal.remove({
      generation: "1",
      targetId: "one",
      token: attachment("a").token,
      target: drafts,
      release: () => gate.promise,
      recover: async () => assert.fail(),
      unconfirmed: () => assert.fail(),
    });
  });
  removal.dispose();
  gate.reject(new Error("late rejection"));
  await pending;
  assert.deepEqual(states, [false, true]);
  assert.equal(removal.busy, false);
});

for (const recoveryFails of [false, true]) {
  test(`unknown release preserves text and invalidates grants; recovery rejects=${recoveryFails}`, async () => {
    let drafts;
    function Harness() {
      drafts = useTaskDrafts("one");
      return null;
    }
    render(createElement(Harness));
    act(() =>
      drafts.updateDraft({
        kind: "multimodal",
        text: "keep",
        attachments: [attachment("a"), attachment("b")],
      }),
    );
    const removal = new AttachmentRemovalCoordinator(() => {});
    removal.resetGeneration("1");
    const gate = deferred();
    let reported = 0,
      recovered = 0,
      pending;
    act(() => {
      pending = removal.remove({
        generation: "1",
        targetId: "one",
        token: attachment("a").token,
        target: drafts,
        release: () => gate.promise,
        unconfirmed: () => reported++,
        recover: async (generation) => {
          assert.equal(generation, "1");
          recovered++;
          drafts.invalidateAttachments();
          if (recoveryFails) throw new Error("recovery failed");
        },
      });
    });
    act(() =>
      drafts.updateDraft({ ...drafts.currentDraft("one"), text: "new text" }),
    );
    await act(async () => {
      gate.reject(new Error("untyped Host failure"));
      await pending;
    });
    assert.equal(reported, 1);
    assert.equal(recovered, 1);
    assert.equal(removal.busy, false);
    assert.deepEqual(drafts.currentDraft("one"), {
      kind: "text",
      text: "new text",
      attachmentsReloadRequired: true,
    });
  });
}

async function fixture(ctx, { batches, cancelResult } = {}) {
  window.sessionStorage.clear();
  const snapshot = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  snapshot.capabilities.automaticWorkspaces = true;
  const first = snapshot.tasks[0];
  Object.assign(first, {
    title: "First attachment task",
    currentRunPhase: "completed",
    activeOperation: null,
  });
  snapshot.tasks.push({
    ...structuredClone(first),
    id: "4",
    title: "Second attachment task",
  });
  const releases = [],
    adds = [],
    runs = [];
  let drops;
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onTaskOpen: () => () => {},
    onWorkbenchRevision: () => () => {},
    onFileDrop: (callback) => {
      drops = callback;
      return () => {};
    },
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    releaseAttachment: (token) => {
      const gate = deferred();
      releases.push({ token, ...gate });
      return gate.promise;
    },
    createAttachmentAdd: (_recover, remainingFiles) => {
      const add = { remainingFiles, cancelled: false };
      adds.push(add);
      return {
        run: async () => ({
          status: "ready",
          attachments: batches
            ? batches.shift()
            : [attachment("a"), attachment("b")],
        }),
        handoff: (commit) => commit(),
        cancel: async () => {
          add.cancelled = true;
          return cancelResult ?? { status: "cleaned", released: true };
        },
      };
    },
    run: async (...args) => {
      runs.push(args);
      throw new Error("unexpected run");
    },
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
  const select = async (title) => {
    const buttons = await screen.findAllByRole("button", {
      name: new RegExp(title),
    });
    await act(async () => {
      fireEvent.click(
        buttons.find((button) => button.closest(".task-list-item")) ??
          buttons[0],
      );
    });
  };
  await select("First attachment task");
  await screen.findByRole("button", { name: "Add to message" });
  return { releases, adds, runs, select, drop: (paths) => drops(paths) };
}

async function chooseFiles(user = userEvent.setup({ document })) {
  await user.click(screen.getByRole("button", { name: "Add to message" }));
  await user.click(await screen.findByRole("menuitem", { name: "Add files" }));
}

test("App removal blocks rapid add/send/drop, preserves typing and never writes another Task", async (ctx) => {
  const f = await fixture(ctx);
  const user = userEvent.setup({ document });
  await chooseFiles(user);
  await screen.findByRole("button", { name: "Remove a.html" });
  const textbox = document.querySelector("textarea");
  fireEvent.change(textbox, { target: { value: "first text" } });
  await user.click(screen.getByRole("button", { name: "Remove a.html" }));
  assert.equal(f.releases.length, 1);
  assert.equal(screen.queryByRole("button", { name: "Remove a.html" }), null);
  assert.equal(
    screen.getByRole("button", { name: "Removing file…" }).disabled,
    true,
  );
  fireEvent.click(screen.getByRole("button", { name: "Removing file…" }));
  fireEvent.click(screen.getByRole("button", { name: "Remove b.html" }));
  act(() => f.drop(["/tmp/late.html"]));
  fireEvent.keyDown(textbox, { key: "Enter" });
  assert.equal(f.adds.length, 1);
  assert.equal(f.runs.length, 0);
  assert.equal(f.releases.length, 1);
  fireEvent.change(textbox, { target: { value: "edited first text" } });
  await f.select("Second attachment task");
  fireEvent.change(document.querySelector("textarea"), {
    target: { value: "second text" },
  });
  await act(async () => {
    f.releases[0].resolve({ released: true });
  });
  assert.equal(document.querySelector("textarea").value, "second text");
  assert.equal(screen.queryByRole("button", { name: "Remove b.html" }), null);
  await f.select("First attachment task");
  assert.equal(document.querySelector("textarea").value, "edited first text");
  assert.ok(screen.getByRole("button", { name: "Remove b.html" }));
});

test("App ignores unconfirmed feedback after leaving and returning to the same scope", async (ctx) => {
  const f = await fixture(ctx);
  await chooseFiles();
  fireEvent.click(await screen.findByRole("button", { name: "Remove a.html" }));
  fireEvent.change(document.querySelector("textarea"), {
    target: { value: "keep this text" },
  });
  await f.select("Second attachment task");
  await f.select("First attachment task");
  await act(async () => {
    f.releases[0].reject(new Error("CleanupFailed"));
  });
  await waitFor(() =>
    assert.equal(
      screen.queryByRole("button", { name: "Removing file…" }),
      null,
    ),
  );
  await f.select("First attachment task");
  assert.equal(screen.queryByText(/File cleanup could not be confirmed/), null);
  assert.equal(screen.queryByRole("button", { name: "Remove b.html" }), null);
  assert.ok(
    screen.getByText(
      "Unsent attachments are not kept after reload. Add them again before sending.",
    ),
  );
  assert.equal(document.querySelector("textarea").value, "keep this text");
});

test("App waits for release before restoring adjacent focus and never interrupts typing", async (ctx) => {
  const f = await fixture(ctx);
  const user = userEvent.setup({ document });
  await chooseFiles(user);
  await user.click(
    await screen.findByRole("button", { name: "Remove a.html" }),
  );
  const adjacent = screen.getByRole("button", { name: "Remove b.html" });
  assert.equal(adjacent.disabled, true);
  await user.click(document.querySelector("textarea"));
  fireEvent.change(document.querySelector("textarea"), {
    target: { value: "still typing" },
  });
  await act(async () => {
    f.releases[0].resolve({ released: false });
  });
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(document.activeElement, document.querySelector("textarea"));
  assert.equal(adjacent.disabled, false);
  assert.equal(document.querySelector("textarea").value, "still typing");
  assert.equal(f.releases.length, 1);
});

const attachmentBatch = (start, count) =>
  Array.from({ length: count }, (_, index) => ({
    token: (start + index).toString(16).padStart(48, "0"),
    kind: "image",
    format: "jpeg",
    displayName: `shot-${start + index}.jpg`,
    sizeBytes: "120000",
  }));
const visibleAttachments = () =>
  screen.queryAllByRole("button", { name: /^Remove shot-/ });

test("App allows 5+3 in one message and full drafts coexist with other Task and New task drafts", async (ctx) => {
  const f = await fixture(ctx, {
    batches: [
      attachmentBatch(0, 5),
      attachmentBatch(5, 3),
      attachmentBatch(8, 1),
      attachmentBatch(9, 1),
    ],
  });
  fireEvent.change(document.querySelector("textarea"), {
    target: { value: "keep original text" },
  });
  await chooseFiles();
  await waitFor(() => assert.equal(visibleAttachments().length, 5));
  await chooseFiles();
  await waitFor(() => assert.equal(visibleAttachments().length, 8));
  assert.deepEqual(
    f.adds.map((add) => add.remainingFiles),
    [8, 3],
  );
  await chooseFiles();
  await screen.findByText("You can attach up to 8 files per message.");
  assert.equal(f.adds.length, 2);
  assert.equal(visibleAttachments().length, 8);
  await f.select("Second attachment task");
  await waitFor(() => assert.equal(visibleAttachments().length, 0));
  await chooseFiles();
  await waitFor(() => assert.equal(visibleAttachments().length, 1));
  assert.equal(f.adds[2].remainingFiles, 8);
  fireEvent.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  await waitFor(() => assert.equal(visibleAttachments().length, 0));
  await chooseFiles();
  await waitFor(() => assert.equal(visibleAttachments().length, 1));
  assert.equal(f.adds[3].remainingFiles, 8);
  await f.select("First attachment task");
  assert.equal(visibleAttachments().length, 8);
  assert.equal(document.querySelector("textarea").value, "keep original text");
});

for (const source of ["drop", "paste"]) {
  test(`App rejects 7+2 ${source} before creating an operation or reading files`, async (ctx) => {
    const f = await fixture(ctx, { batches: [attachmentBatch(0, 7)] });
    await chooseFiles();
    await waitFor(() => assert.equal(visibleAttachments().length, 7));
    const textbox = document.querySelector("textarea");
    fireEvent.change(textbox, { target: { value: "still editable" } });
    if (source === "drop") act(() => f.drop(["/tmp/one.jpg", "/tmp/two.jpg"]));
    else {
      const files = [
        new File(["one"], "one.png", { type: "image/png" }),
        new File(["two"], "two.png", { type: "image/png" }),
      ];
      for (const file of files)
        file.slice = () =>
          assert.fail("oversized selection must not read files");
      fireEvent.paste(textbox, {
        clipboardData: {
          items: files.map((file) => ({
            kind: "file",
            type: file.type,
            getAsFile: () => file,
          })),
        },
      });
    }
    await screen.findByText("You can attach up to 8 files per message.");
    assert.equal(f.adds.length, 1);
    assert.equal(visibleAttachments().length, 7);
    assert.equal(textbox.value, "still editable");
  });
}

for (const cleanupFailed of [false, true]) {
  test(`App cancels an oversized ready batch without handing it into the draft (cleanup failed ${cleanupFailed})`, async (ctx) => {
    const f = await fixture(ctx, {
      batches: [attachmentBatch(0, 7), attachmentBatch(7, 2)],
      cancelResult: cleanupFailed ? { status: "cleanup_failed" } : undefined,
    });
    await chooseFiles();
    await waitFor(() => assert.equal(visibleAttachments().length, 7));
    await chooseFiles();
    await waitFor(() => assert.equal(f.adds[1]?.cancelled, true));
    await screen.findByText(
      cleanupFailed
        ? "Attachment cleanup is incomplete and some resources are still in use. Try again later."
        : "You can attach up to 8 files per message.",
    );
    assert.equal(f.adds[1].remainingFiles, 1);
    assert.equal(visibleAttachments().length, 7);
  });
}
