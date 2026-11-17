import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";

import { repositoryRoot } from "./build.mjs";
import { discoverNodeTests } from "./run-tests.mjs";

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
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
});

const { screen, waitFor } = await import("./renderer-testing-library.mjs");

test.after(() => dom.window.close());

// Every shape that would hand a test file the library's own exports: both
// static import forms and the dynamic one.
const directImport =
  /(?:\bfrom\s*|\bimport\s*\(?\s*)["']@testing-library\/react["']/;

// Discovery, not a list: every file the runner executes is checked, so a new
// renderer test inherits the shared budget instead of quietly reintroducing
// the library default.
test("renderer tests reach testing-library through the shared budget", async () => {
  const files = await discoverNodeTests(repositoryRoot);
  assert.ok(files.length > 0, "no scripts/*.test.mjs were discovered");
  const offenders = [];
  for (const file of files) {
    const source = await readFile(path.join(repositoryRoot, file), "utf8");
    if (directImport.test(source)) offenders.push(file);
  }
  assert.deepEqual(
    offenders,
    [],
    "these tests import the React testing library directly; import ./renderer-testing-library.mjs instead, which re-exports it with the shared asyncUtilTimeout already configured for this process",
  );
});

// The two waits below are the evidence that the budget is in force. They share
// one condition: an element that only reaches the document after
// lateArrivalMs, slower than the library default and faster than the shared
// budget. The first wait states a default-sized budget and has to fail; the
// second states no budget at all and has to succeed. Without the pair, a
// configure() call that never reached the library's own config would leave
// every renderer test green and every wait still bounded at one second.
const defaultBudgetMs = 1000;
const lateArrivalMs = 2000;

function scheduleLateArrival() {
  const marker = dom.window.document.createElement("div");
  marker.dataset.testid = "late-arrival";
  const timer = setTimeout(
    () => dom.window.document.body.append(marker),
    lateArrivalMs,
  );
  return () => {
    clearTimeout(timer);
    marker.remove();
  };
}

const findLateArrival = () => screen.getByTestId("late-arrival");

test("a default-sized budget abandons a wait this slow", async () => {
  const cancel = scheduleLateArrival();
  try {
    await assert.rejects(
      waitFor(findLateArrival, { timeout: defaultBudgetMs }),
      /Unable to find an element by: \[data-testid="late-arrival"\]/,
    );
  } finally {
    cancel();
  }
});

test("the shared budget carries the same wait to completion", async () => {
  const cancel = scheduleLateArrival();
  try {
    const started = Date.now();
    const marker = await waitFor(findLateArrival);
    const elapsed = Date.now() - started;
    assert.equal(marker.dataset.testid, "late-arrival");
    assert.ok(
      elapsed > defaultBudgetMs,
      `the wait completed in ${elapsed}ms, within the ${defaultBudgetMs}ms library default, so it proves nothing about the shared budget`,
    );
  } finally {
    cancel();
  }
});
