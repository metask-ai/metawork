import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

import { enUS } from "../frontend/src/i18n/messages/en-US.ts";
import { zhCN } from "../frontend/src/i18n/messages/zh-CN.ts";
import { taskCountMessageId } from "../frontend/src/i18n/formatters.ts";
import { initialLocale, translate } from "../frontend/src/i18n/runtime.ts";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../frontend/src/platform/local-preferences.ts";

function placeholders(message) {
  return [...message.matchAll(/\{([a-zA-Z0-9_]+)\}/g)]
    .map((match) => match[1])
    .sort();
}

async function productSourceFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const sources = [];
  for (const entry of entries) {
    const url = new URL(
      `${entry.name}${entry.isDirectory() ? "/" : ""}`,
      directory,
    );
    if (entry.isDirectory()) sources.push(...(await productSourceFiles(url)));
    else if (entry.name.endsWith(".tsx")) sources.push(url);
  }
  return sources;
}

test("English is the complete source catalog and zh-CN has exact key parity", () => {
  assert.deepEqual(Object.keys(zhCN).sort(), Object.keys(enUS).sort());
  assert.equal(Object.values(enUS).every(Boolean), true);
  assert.equal(Object.values(zhCN).every(Boolean), true);
  for (const id of Object.keys(enUS)) {
    assert.deepEqual(placeholders(zhCN[id]), placeholders(enUS[id]), id);
  }
});

test("command bar product copy never interpolates raw diagnostics", () => {
  const attentionMessages = [
    "workspace.selection_failed",
    "task.create_failed",
    "task.rename_failed",
    "task.archive_failed",
    "task.restore_failed",
    "task.delete_failed",
    "run.start_failed",
    "run.stop_failed",
    "approval.response_failed",
    "view.refresh_after_commit_failed",
  ];
  for (const id of attentionMessages) {
    assert.equal(enUS[id].includes("{error}"), false, id);
    assert.equal(zhCN[id].includes("{error}"), false, id);
  }
});

test("Metask authorization rejection tells the user to sign in again", () => {
  assert.match(enUS["account.error.metask_access"], /sign in again/iu);
  assert.doesNotMatch(enUS["account.error.metask_access"], /kept/iu);
  assert.match(zhCN["account.error.metask_access"], /重新登录/u);
  assert.doesNotMatch(zhCN["account.error.metask_access"], /保留/u);
});

test("task counts follow locale plural rules", () => {
  assert.equal(taskCountMessageId("en-US", 1), "task.count.one");
  assert.equal(taskCountMessageId("en-US", 0), "task.count.other");
  assert.equal(taskCountMessageId("zh-CN", 1), "task.count.other");
  assert.equal(taskCountMessageId("pseudo", 1), "task.count.one");
});

test("optional local preferences cannot break startup", () => {
  const previousWindow = globalThis.window;
  globalThis.window = {
    get localStorage() {
      throw new Error("storage denied");
    },
  };
  try {
    assert.equal(readLocalPreference("locale"), null);
    assert.doesNotThrow(() => writeLocalPreference("locale", "en-US"));
  } finally {
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
  }
});

test("locale selection honors a saved choice and otherwise follows the system", () => {
  assert.equal(initialLocale("en-US", ["zh-CN"]), "en-US");
  assert.equal(initialLocale("pseudo", ["zh-CN"]), "zh-CN");
  assert.equal(initialLocale("pseudo", ["zh-CN"], true), "pseudo");
  assert.equal(initialLocale(null, ["zh-Hans-CN", "en-US"]), "zh-CN");
  assert.equal(initialLocale(null, ["fr-FR"]), "en-US");
});

test("runtime translation interpolates values and pseudo-locale expands copy", () => {
  assert.equal(translate("en-US", "task.item", { id: 7 }), "Task 7");
  assert.equal(translate("zh-CN", "task.item", { id: 7 }), "任务 7");
  const pseudo = translate("pseudo", "task.item", { id: 7 });
  assert.match(pseudo, /^［/);
  assert.match(pseudo, /7/);
  assert.ok(pseudo.length >= enUS["task.item"].length * 1.3);
});

test("application product copy is catalog-backed", async () => {
  const sourceFiles = await productSourceFiles(
    new URL("../frontend/src/", import.meta.url),
  );
  const sources = await Promise.all(
    sourceFiles.map((path) => readFile(path, "utf8")),
  );
  const source = sources.join("\n");
  const staticMessageIds = [...source.matchAll(/\bt\("([a-z0-9_.-]+)"/g)].map(
    (match) => match[1],
  );
  for (const id of staticMessageIds) {
    assert.equal(
      Object.hasOwn(enUS, id),
      true,
      `missing source message: ${id}`,
    );
  }
  for (const obsolete of [
    "Run desk",
    "Decision desk",
    "Create session",
    "Open a Session",
    "Host status",
  ]) {
    assert.equal(source.includes(obsolete), false, obsolete);
  }
});
