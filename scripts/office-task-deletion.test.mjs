import assert from "node:assert/strict";
import { mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { verifyOfficeTaskDeletion } from "./office-skill-vertical.mjs";

test("Office deletion probe waits for Task retirement before checking originals", async () => {
  const root = await mkdtemp(join(tmpdir(), "metawork-office-delete-"));
  try {
    const original = join(root, "original.docx");
    await writeFile(original, "synthetic original");
    let tasks = [{ id: "3", lifecycle: "closing" }];
    let observations = 0;
    await verifyOfficeTaskDeletion({
      taskId: "3",
      originals: [original],
      snapshot: async () => {
        observations++;
        return { tasks };
      },
      poll: async (observe, timeout, label) => {
        assert.equal(timeout, 20_000);
        assert.equal(label, "Office Task deletion committed");
        assert.equal(await observe(), null);
        await unlink(original);
        tasks = [];
        assert.equal(await observe(), true);
      },
    });
    assert.equal(observations, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Office deletion probe still fails if an original survives committed deletion", async () => {
  const root = await mkdtemp(join(tmpdir(), "metawork-office-delete-"));
  try {
    const original = join(root, "original.docx");
    await writeFile(original, "synthetic residual");
    await assert.rejects(
      verifyOfficeTaskDeletion({
        taskId: "3",
        originals: [original],
        snapshot: async () => ({ tasks: [] }),
        poll: async (observe) => assert.equal(await observe(), true),
      }),
      /Missing expected rejection/,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
