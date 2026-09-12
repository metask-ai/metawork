import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  completionAcknowledgementCandidate,
  completionReminderSuppressionTaskId,
} from "../frontend/src/app/completion-receipt.ts";
import { documentHasAttention } from "../frontend/src/app/document-attention.ts";

const task = { id: "3", unreadCompletionRunId: "7" };
const visible = {
  task,
  workbenchRoute: true,
  settingsOpen: false,
  searchOpen: false,
  modalOpen: false,
  taskStageExposed: true,
  documentAttention: true,
  bridgeAvailable: true,
};

test("completion acknowledgement requires the genuine foreground Task stage", () => {
  assert.deepEqual(completionAcknowledgementCandidate(visible), {
    taskId: "3",
    runId: "7",
    key: "3:7",
  });

  for (const override of [
    { task: null },
    { task: { ...task, unreadCompletionRunId: null } },
    { workbenchRoute: false },
    { settingsOpen: true },
    { searchOpen: true },
    { modalOpen: true },
    { taskStageExposed: false },
    { documentAttention: false },
    { bridgeAvailable: false },
  ])
    assert.equal(
      completionAcknowledgementCandidate({ ...visible, ...override }),
      null,
    );
});

test("document attention requires both visibility and window focus", () => {
  assert.equal(
    documentHasAttention({ visibilityState: "visible", hasFocus: () => true }),
    true,
  );
  assert.equal(
    documentHasAttention({ visibilityState: "hidden", hasFocus: () => true }),
    false,
  );
  assert.equal(
    documentHasAttention({ visibilityState: "visible", hasFocus: () => false }),
    false,
  );
});

test("a failed acknowledgement immediately restores the canonical reminder", () => {
  const acknowledgement = completionAcknowledgementCandidate(visible);
  assert.equal(completionReminderSuppressionTaskId(acknowledgement, null), "3");
  assert.equal(
    completionReminderSuppressionTaskId(acknowledgement, "3:7"),
    null,
  );
});

test("App rejects stale receipts and never acknowledges behind the new Task surface", async () => {
  const source = await readFile(
    new URL("../frontend/src/app/App.tsx", import.meta.url),
    "utf8",
  );
  assert.match(
    source,
    /if \(current && !marked\) setCompletionAcknowledgementFailure\(key\)/,
  );
  assert.match(source, /task: newTaskDraftActive \? null : activeTask/);
});
