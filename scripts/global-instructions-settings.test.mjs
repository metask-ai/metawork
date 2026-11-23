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
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  HTMLTextAreaElement: dom.window.HTMLTextAreaElement,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

const { cleanup, fireEvent, render, screen, waitFor } =
  await import("./renderer-testing-library.mjs");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { GlobalInstructionsSettings } = await vite.ssrLoadModule(
  "/src/features/settings/GlobalInstructionsSettings.tsx",
);
const { decodeGlobalInstructions, decodeGlobalInstructionsSaveResult } =
  await vite.ssrLoadModule("/src/bridge/decode-contracts.ts");
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => vite.close());
test.afterEach(() => cleanup());

const path = "/home/user/.metawork/AGENTS.md";
const digest = (fill) => fill.repeat(64);

function view(overrides = {}) {
  return {
    path,
    state: "ready",
    text: "Answer in English.",
    revision: digest("a"),
    byteLength: "18",
    reason: null,
    limitBytes: 32768,
    ...overrides,
  };
}

function editor(actions, locale = "en-US") {
  return render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale,
          setLocale() {},
          t: (id, values) => translate(locale, id, values),
        },
      },
      createElement(GlobalInstructionsSettings, { actions, disabled: false }),
    ),
  );
}

function actions(
  read,
  save = async () => ({ outcome: "saved", revision: digest("b") }),
) {
  const calls = { reads: 0, saves: [] };
  return {
    calls,
    read: async () => {
      calls.reads += 1;
      return typeof read === "function" ? read(calls.reads) : read;
    },
    save: async (expectedRevision, text) => {
      calls.saves.push({ expectedRevision, text });
      return save(expectedRevision, text);
    },
  };
}

test("the editor shows the Host's path and text and saves against the loaded revision", async () => {
  const host = actions(view());
  editor(host);
  const box = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  assert.equal(box.value, "Answer in English.");
  assert.equal(screen.getByText(path).textContent, path);
  const save = screen.getByRole("button", { name: "Save" });
  // Nothing changed yet, so nothing to save.
  assert.equal(save.disabled, true);
  fireEvent.change(box, { target: { value: "Answer in Chinese." } });
  assert.equal(save.disabled, false);
  assert.match(screen.getByText(/bytes$/u).textContent, /^18 \/ 32768 bytes$/u);
  fireEvent.click(save);
  await screen.findByText(/^Saved\./u);
  assert.deepEqual(host.calls.saves, [
    { expectedRevision: digest("a"), text: "Answer in Chinese." },
  ]);
  // The saved text is the new baseline, and the next save names its revision.
  assert.equal(screen.getByRole("button", { name: "Save" }).disabled, true);
  fireEvent.change(box, { target: { value: "Answer briefly." } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.equal(host.calls.saves.length, 2));
  assert.equal(host.calls.saves[1].expectedRevision, digest("b"));
});

test("a file with CRLF line breaks keeps them, and only an edit counts as a change", async () => {
  const host = actions(view({ text: "one\r\ntwo\r\n", byteLength: "10" }));
  editor(host);
  const box = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  // The textarea reports every break as LF; the text is unchanged all the same.
  fireEvent.change(box, { target: { value: "one\ntwo\n" } });
  assert.equal(screen.getByRole("button", { name: "Save" }).disabled, true);
  // Counted as it will be written, CRLF included.
  assert.match(screen.getByText(/bytes$/u).textContent, /^10 \/ 32768 bytes$/u);
  fireEvent.change(box, { target: { value: "one\ntwo\nthree\n" } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.equal(host.calls.saves.length, 1));
  assert.equal(host.calls.saves[0].text, "one\r\ntwo\r\nthree\r\n");
  await screen.findByText(/^Saved\./u);
  assert.equal(screen.getByRole("button", { name: "Save" }).disabled, true);
  cleanup();

  // A file with LF breaks stays LF.
  const plain = actions(view({ text: "one\ntwo" }));
  editor(plain);
  const lf = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  fireEvent.change(lf, { target: { value: "one\ntwo\nthree" } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.equal(plain.calls.saves.length, 1));
  assert.equal(plain.calls.saves[0].text, "one\ntwo\nthree");
});

test("a missing file is created by the first save, against the absent revision", async () => {
  const host = actions(
    view({ state: "absent", text: null, revision: "absent", byteLength: null }),
  );
  editor(host);
  await screen.findByText("This file does not exist yet. Saving creates it.");
  const box = screen.getByRole("textbox", {
    name: "Instructions for every task",
  });
  assert.equal(box.value, "");
  fireEvent.change(box, { target: { value: "Keep replies short." } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await waitFor(() => assert.equal(host.calls.saves.length, 1));
  assert.equal(host.calls.saves[0].expectedRevision, "absent");
});

test("text over the limit cannot be saved and says why, counted in UTF-8 bytes", async () => {
  const host = actions(view({ limitBytes: 6 }));
  editor(host);
  const box = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  // Two characters, six bytes: exactly at the limit.
  fireEvent.change(box, { target: { value: "中文" } });
  assert.equal(screen.getByRole("button", { name: "Save" }).disabled, false);
  fireEvent.change(box, { target: { value: "中文!" } });
  assert.equal(screen.getByRole("button", { name: "Save" }).disabled, true);
  assert.match(screen.getByRole("alert").textContent, /at most 32 KiB/u);
  assert.equal(host.calls.saves.length, 0);
});

test("an outside change is shown before anything overwrites it", async () => {
  let current = view();
  const host = actions(
    () => current,
    async (expected) =>
      expected === digest("c")
        ? { outcome: "saved", revision: digest("d") }
        : { outcome: "conflict", revision: digest("c") },
  );
  editor(host);
  const box = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  fireEvent.change(box, { target: { value: "Mine." } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await screen.findByText(/changed outside MetaWork/u);
  // The draft is kept until the user chooses.
  assert.equal(box.value, "Mine.");
  // Overwriting names the revision the Host reported, once the user asks.
  fireEvent.click(screen.getByRole("button", { name: "Overwrite" }));
  await screen.findByText(/^Saved\./u);
  assert.equal(host.calls.saves[1].expectedRevision, digest("c"));

  // Reloading replaces the draft with the outside version.
  cleanup();
  current = view({ text: "Outside.", revision: digest("e") });
  const reloading = actions(
    () => current,
    async () => ({ outcome: "conflict", revision: digest("e") }),
  );
  editor(reloading);
  const second = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  fireEvent.change(second, { target: { value: "Mine." } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await screen.findByText(/changed outside MetaWork/u);
  fireEvent.click(screen.getByRole("button", { name: "Reload" }));
  // Reloading reads the file again; the editor shows the outside version.
  await waitFor(() =>
    assert.equal(
      screen.getByRole("textbox", { name: "Instructions for every task" })
        .value,
      "Outside.",
    ),
  );
  assert.equal(reloading.calls.reads, 2);
});

test("files the editor must not show point to the path instead, in both languages", async () => {
  for (const [state, overrides, english] of [
    [
      "contains_credential",
      { revision: null },
      /Open the path above in another editor to change it/u,
    ],
    [
      "too_large",
      { revision: null, byteLength: "200000" },
      /200000 bytes, too large to edit here/u,
    ],
    [
      "unreadable",
      { revision: null, reason: "not_utf8" },
      /cannot be read as text/u,
    ],
  ]) {
    editor(actions(view({ state, text: null, ...overrides })));
    await screen.findByText(english);
    assert.equal(screen.queryByRole("textbox"), null);
    assert.equal(screen.getByText(path).textContent, path);
    cleanup();
  }
  editor(
    actions(view({ state: "contains_credential", text: null, revision: null })),
    "zh-CN",
  );
  await screen.findByText(/请用其他编辑器打开上面的路径修改/u);
  cleanup();
  editor(
    actions(
      view({
        state: "unavailable",
        path: null,
        text: null,
        revision: null,
        byteLength: null,
      }),
    ),
  );
  await screen.findByText(/no home folder/u);
  assert.equal(screen.queryByRole("textbox"), null);
});

test("a refused or failed save keeps the text and says why", async () => {
  for (const [outcome, message] of [
    ["contains_credential", /credential MetaWork stores, so it was not saved/u],
    ["write_failed", /could not be saved/u],
    ["invalid_text", /cannot be saved/u],
  ]) {
    editor(actions(view(), async () => ({ outcome, revision: null })));
    const box = await screen.findByRole("textbox", {
      name: "Instructions for every task",
    });
    fireEvent.change(box, { target: { value: "Changed." } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await screen.findByText(message);
    assert.equal(box.value, "Changed.");
    cleanup();
  }
  editor(
    actions(view(), async () => {
      throw new Error("bridge unavailable");
    }),
  );
  const box = await screen.findByRole("textbox", {
    name: "Instructions for every task",
  });
  fireEvent.change(box, { target: { value: "Changed." } });
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await screen.findByText(/could not be saved/u);
});

test("the Host's editor answers decode strictly", () => {
  for (const valid of [
    view(),
    view({ state: "absent", text: null, revision: "absent", byteLength: null }),
    view({
      state: "too_large",
      text: null,
      revision: null,
      byteLength: "200000",
    }),
    view({
      state: "unreadable",
      text: null,
      revision: null,
      reason: "access_denied",
      byteLength: null,
    }),
    view({ state: "contains_credential", text: null, revision: null }),
    view({
      state: "unavailable",
      path: null,
      text: null,
      revision: null,
      byteLength: null,
    }),
  ])
    assert.deepEqual(decodeGlobalInstructions(valid), valid);
  for (const invalid of [
    view({ text: null }),
    view({ revision: null }),
    view({ revision: "ABC" }),
    view({ state: "absent", text: null, revision: digest("a") }),
    view({ state: "contains_credential", text: "leaked" }),
    view({ state: "contains_credential", text: null, revision: digest("a") }),
    view({ state: "unreadable", text: null, revision: null }),
    view({ state: "too_large", text: null, revision: null, byteLength: null }),
    view({ state: "unavailable", text: null, revision: null }),
    view({ path: null }),
    view({ limitBytes: 0 }),
    { ...view(), extra: true },
  ])
    assert.throws(() => decodeGlobalInstructions(invalid));

  for (const valid of [
    { outcome: "saved", revision: digest("a") },
    { outcome: "conflict", revision: "absent" },
    { outcome: "too_large", revision: null },
    { outcome: "unavailable", revision: null },
  ])
    assert.deepEqual(decodeGlobalInstructionsSaveResult(valid), valid);
  for (const invalid of [
    { outcome: "saved", revision: null },
    { outcome: "saved", revision: "absent" },
    { outcome: "write_failed", revision: digest("a") },
    { outcome: "retired", revision: null },
  ])
    assert.throws(() => decodeGlobalInstructionsSaveResult(invalid));
});
