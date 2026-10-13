import assert from "node:assert/strict";
import test from "node:test";
import { SkillPreparationCoordinator } from "../frontend/src/app/skill-preparation.ts";
import { submitTaskInstruction } from "../frontend/src/features/composer/submitTaskInstruction.ts";

const target = { taskId: "9", bindingEpoch: "12", generation: "3" };
const task = (availability = "loading", overrides = {}) => ({
  id: "9",
  binding: { epoch: "12" },
  archived: false,
  lifecycle: "open",
  activeOperation: null,
  skillCatalog: { availability },
  ...overrides,
});

test("first submission waits for the exact Task catalog and sends once", async () => {
  const coordinator = new SkillPreparationCoordinator();
  coordinator.resetGeneration("3");
  let runs = 0,
    created = 0;
  const promise = submitTaskInstruction({
    client: {
      createTask: async () => ({
        accepted: true,
        taskId: "9",
        bindingEpoch: "12",
      }),
      run: async () => {
        runs++;
        return { accepted: true, runId: "1" };
      },
    },
    taskId: null,
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "1",
    expectedSelectionRevision: "1",
    modelSelection: null,
    expectedBindingEpoch: null,
    approvalMode: "manual",
    input: { kind: "text", text: "Analyze this document" },
    onTaskCreated: () => {
      created++;
    },
    ensureSkills: () => coordinator.wait(target, 1000),
  });
  await Promise.resolve();
  coordinator.observeSnapshot({ tasks: [task()] }, "3");
  await Promise.resolve();
  assert.equal(created, 1);
  assert.equal(runs, 0);
  coordinator.observeSnapshot({ tasks: [task("ready")] }, "2");
  assert.equal(runs, 0);
  coordinator.observeSnapshot({ tasks: [task("ready")] }, "3");
  assert.equal((await promise).kind, "started");
  assert.equal(runs, 1);
  coordinator.dispose();
});

test("explicit Skill unavailability settles preparation without blocking ordinary text", async () => {
  const coordinator = new SkillPreparationCoordinator();
  coordinator.resetGeneration("3");
  const promise = coordinator.wait(target, 1000);
  coordinator.observeSnapshot({ tasks: [task("unavailable")] }, "3");
  assert.equal((await promise).kind, "ready");
  coordinator.dispose();
});

test("timeout never starts a Run and retains the created Task identity", async () => {
  const coordinator = new SkillPreparationCoordinator();
  coordinator.resetGeneration("3");
  let runs = 0;
  const result = await submitTaskInstruction({
    client: {
      run: async () => {
        runs++;
        return { accepted: true };
      },
    },
    taskId: "9",
    expectedBindingEpoch: "12",
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "1",
    expectedSelectionRevision: "1",
    modelSelection: null,
    approvalMode: "manual",
    input: { kind: "text", text: "Keep this draft" },
    onTaskCreated: () => {},
    ensureSkills: () => coordinator.wait(target, 1),
  });
  assert.equal(result.kind, "run_failed");
  assert.equal(result.taskId, "9");
  coordinator.observeSnapshot({ tasks: [task("ready")] }, "3");
  assert.equal(runs, 0);
  coordinator.dispose();
});

test("binding changes, deletion, focus changes and connection replacement cancel waits", async () => {
  for (const mutate of [
    (c) =>
      c.observeSnapshot(
        { tasks: [task("ready", { binding: { epoch: "13" } })] },
        "3",
      ),
    (c) => c.observeSnapshot({ tasks: [] }, "3"),
    (c) => c.cancelExceptTask("10"),
    (c) => c.resetGeneration("4"),
  ]) {
    const coordinator = new SkillPreparationCoordinator();
    coordinator.resetGeneration("3");
    coordinator.observeSnapshot({ tasks: [task()] }, "3");
    const promise = coordinator.wait(target, 1000);
    mutate(coordinator);
    assert.equal((await promise).kind, "failed");
    coordinator.dispose();
  }
});
