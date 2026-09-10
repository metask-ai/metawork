import assert from "node:assert/strict";
import test from "node:test";

import {
  composerDraftToRunInput,
  isSkillDraftCurrent,
  parseSlashInput,
  resolveSlashCandidates,
  resolveSlashCommandStates,
  skillCatalogRefreshTarget,
  slashCommandNames,
  skillDraftFromCandidate,
} from "../frontend/src/features/composer/slash.ts";

const catalog = {
  availability: "ready",
  redacted: false,
  revision: "17",
  selectionRevision: "3",
  skills: [
    {
      skillId: "workspace.new",
      invocationName: "new",
      displayName: "Prepare new files",
      description: "Prepare files for a new change",
      argumentNames: [],
      maxValues: 0,
      enabled: true,
    },
    {
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      description: "Review a target",
      argumentNames: ["target"],
      maxValues: 1,
      enabled: true,
    },
  ],
  issues: [],
};

test("Slash resolver keeps Commands authoritative over colliding Skill names", () => {
  const commands = [{ name: "new", enabled: true, disabledReason: null }];
  assert.deepEqual(
    resolveSlashCandidates({
      input: parseSlashInput("/new"),
      commands,
      catalog,
    }).map((candidate) => candidate.key),
    ["command:new"],
  );
  assert.deepEqual(
    resolveSlashCandidates({
      input: parseSlashInput("/skill:new"),
      commands,
      catalog,
    }).map((candidate) => candidate.key),
    ["skill:workspace.new"],
  );
  const review = resolveSlashCandidates({
    input: parseSlashInput("/review src/main.zig"),
    commands,
    catalog,
  })[0];
  assert.deepEqual(skillDraftFromCandidate(review), {
    kind: "skill",
    skillId: "builtin.review",
    invocationName: "review",
    displayName: "Review",
    catalogRevision: "17",
    selectionRevision: "3",
    argumentNames: ["target"],
    argumentValues: ["src/main.zig"],
    maxValues: 1,
  });
});

test("Slash parsing is limited to one leading identifier token", () => {
  assert.equal(parseSlashInput("Review /tmp/file"), null);
  assert.equal(parseSlashInput("/tmp/file"), null);
  assert.equal(parseSlashInput("https://example.test/review"), null);
  assert.deepEqual(parseSlashInput("/tmp"), {
    query: "tmp",
    tail: "",
    explicitSkill: false,
  });
});

test("Run input conversion rejects unresolved Slash outside the UI layer", () => {
  assert.equal(composerDraftToRunInput({ kind: "text", text: "/new" }), null);
  assert.equal(
    composerDraftToRunInput({ kind: "text", text: "/not-a-command" }),
    null,
  );
  assert.deepEqual(
    composerDraftToRunInput({ kind: "text", text: "/tmp/file" }),
    { kind: "text", text: "/tmp/file" },
  );
  assert.deepEqual(
    composerDraftToRunInput({
      kind: "skill",
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentNames: ["target"],
      argumentValues: ["src/main.zig"],
      maxValues: 1,
    }),
    {
      kind: "skill",
      skillId: "builtin.review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentValues: ["src/main.zig"],
    },
  );
  const attachments = [
    {
      token: "a".repeat(48),
      kind: "image",
      format: "png",
      displayName: "diagram.png",
      sizeBytes: "128",
    },
    {
      token: "b".repeat(48),
      kind: "image",
      format: "webp",
      displayName: "brief.webp",
      sizeBytes: "256",
    },
  ];
  assert.deepEqual(
    composerDraftToRunInput({
      kind: "multimodal",
      text: "Explain these",
      attachments,
    }),
    {
      kind: "multimodal",
      text: "Explain these",
      attachmentTokens: ["a".repeat(48), "b".repeat(48)],
    },
  );
  assert.deepEqual(
    composerDraftToRunInput({
      kind: "multimodal",
      text: "",
      attachments: [attachments[0]],
    }),
    {
      kind: "multimodal",
      text: "",
      attachmentTokens: ["a".repeat(48)],
    },
  );
  assert.deepEqual(
    composerDraftToRunInput({
      kind: "multimodal",
      text: "/review",
      attachments,
    }),
    null,
  );
  assert.deepEqual(
    composerDraftToRunInput({
      kind: "multimodal",
      text: "Read this",
      attachments: [
        {
          token: "c".repeat(48),
          kind: "file",
          displayName: "notes.txt",
          sizeBytes: "64",
        },
      ],
    }),
    {
      kind: "multimodal",
      text: "Read this",
      attachmentTokens: ["c".repeat(48)],
    },
  );
  assert.equal(
    composerDraftToRunInput({
      kind: "multimodal",
      text: " ",
      attachments: [
        {
          token: "c".repeat(48),
          kind: "file",
          displayName: "notes.txt",
          sizeBytes: "64",
        },
      ],
    }),
    null,
  );
});

test("desktop Command registry is explicit and excludes CLI session controls", () => {
  assert.deepEqual(slashCommandNames, ["new", "compact"]);
  for (const legacy of [
    "model",
    "status",
    "resume",
    "continue",
    "history",
    "retry",
    "clear",
    "goal",
    "exit",
  ])
    assert.equal(slashCommandNames.includes(legacy), false);
});

test("Command availability is derived independently for new task and compact", () => {
  assert.deepEqual(
    resolveSlashCommandStates({
      newTaskDraftActive: true,
      bridgeUnavailable: false,
      taskMutationDisabled: false,
      task: null,
    }),
    [
      {
        name: "new",
        enabled: false,
        disabledReason: "already_new_task",
      },
      { name: "compact", enabled: false, disabledReason: "no_history" },
    ],
  );

  const idleTask = {
    lifecycleOpen: true,
    continuationAvailable: true,
    archived: false,
    activeOperation: false,
    hasFinalizedRun: true,
  };
  assert.deepEqual(
    resolveSlashCommandStates({
      newTaskDraftActive: false,
      bridgeUnavailable: false,
      taskMutationDisabled: false,
      task: idleTask,
    }),
    [
      { name: "new", enabled: true, disabledReason: null },
      { name: "compact", enabled: true, disabledReason: null },
    ],
  );
  assert.equal(
    resolveSlashCommandStates({
      newTaskDraftActive: false,
      bridgeUnavailable: false,
      taskMutationDisabled: true,
      task: { ...idleTask, activeOperation: true },
    })[1].disabledReason,
    "task_busy",
  );
});

test("stale Skill drafts retain values but cannot be treated as current", () => {
  const draft = {
    kind: "skill",
    skillId: "builtin.review",
    invocationName: "review",
    displayName: "Review",
    catalogRevision: "16",
    selectionRevision: "3",
    argumentNames: ["target"],
    argumentValues: ["src/main.zig"],
    maxValues: 1,
  };
  assert.equal(isSkillDraftCurrent(draft, catalog), false);
  assert.deepEqual(draft.argumentValues, ["src/main.zig"]);
});

test("Skill refresh repairs Workspace discovery before binding an existing Task", () => {
  const emptyCatalog = (availability) => ({
    availability,
    redacted: false,
    revision: null,
    selectionRevision: null,
    skills: [],
    issues: [],
  });
  assert.equal(
    skillCatalogRefreshTarget(false, emptyCatalog("ready")),
    "workspace",
  );
  assert.equal(
    skillCatalogRefreshTarget(true, emptyCatalog("unavailable")),
    "workspace",
  );
  assert.equal(
    skillCatalogRefreshTarget(true, emptyCatalog("loading")),
    "workspace",
  );
  assert.equal(skillCatalogRefreshTarget(true, emptyCatalog("ready")), "task");
  assert.equal(
    skillCatalogRefreshTarget(true, emptyCatalog("degraded")),
    "task",
  );
});
