import assert from "node:assert/strict";
import test from "node:test";
import { appendHandoffQuote } from "../frontend/src/features/composer/drafts.ts";
import {
  conversationFileReferable,
  conversationFiles,
  replyMentions,
} from "../frontend/src/app/conversation-files.ts";
import {
  composerDraftToRunInput,
  draftWithAttachments,
  maxComposerTextBytes,
} from "../frontend/src/features/composer/slash.ts";

test("conversation file choices keep same-name uploads distinct and deduplicate a workspace output", () => {
  const upload = {
    kind: "file",
    displayName: "报价单.xlsx",
    sizeBytes: "12",
    redacted: false,
    canReference: true,
  };
  function run(id) {
    return {
      id,
      submittedAtUnixMs: id,
      output: {
        commentary: [],
        response: "Use reports/quote.xlsx",
        responseKind: "final",
      },
      submission: null,
      input: { kind: "multimodal", redacted: false, attachments: [upload] },
      outputs: [
        { id: "o", displayPath: "reports/quote.xlsx", redacted: false },
      ],
      fileReferences: {
        media: [],
        links: [{ id: "r", displayPath: "reports/quote.xlsx" }],
      },
    };
  }
  const task = { id: "3", runs: [run("1"), run("2")], inputSubmissions: [] };
  task.runs[1].fileReferences.links.push({
    id: "hidden",
    displayPath: "never-mentioned.txt",
  });
  const files = conversationFiles(task);
  assert.equal(files.length, 3);
  assert.deepEqual(
    files.filter((f) => f.path).map((f) => f.path),
    ["reports/quote.xlsx"],
  );
  assert.deepEqual(
    files.filter((f) => !f.path).map((f) => f.source.attachment.message.runId),
    ["2", "1"],
  );
  const old = { ...upload, canReference: undefined };
  task.runs[0].input.attachments = [
    old,
    { ...upload, redacted: true },
    { ...upload, referenced: true },
  ];
  assert.equal(conversationFiles(task).filter((f) => !f.available).length, 1);
  assert.equal(conversationFiles(task).length, 3);
});
test("referencing a file adds the same attachment input as picking one and preserves the instruction", () => {
  const file = {
    token: "ready",
    kind: "file",
    sizeBytes: "12",
    displayName: "quote.xlsx",
    reference: { key: "stable", detail: "reports/quote.xlsx" },
  };
  const draft = draftWithAttachments(
    { kind: "text", text: "Calculate the tax" },
    [file],
  );
  assert.deepEqual(composerDraftToRunInput(draft), {
    kind: "multimodal",
    attachmentTokens: ["ready"],
    skill: null,
    text: "Calculate the tax",
  });
});
test("Inbox handoff appends its quote once and retains conflicting or over-budget drafts", () => {
  const base = { kind: "text", text: "reply" };
  const first = appendHandoffQuote(base, "Original message");
  assert.equal(first.draft.text, "reply\n\nOriginal message");
  assert.deepEqual(appendHandoffQuote(first.draft, "Original message"), first);
  assert.equal(
    appendHandoffQuote({ kind: "text", text: "/review" }, "quote").kind,
    "preserved",
  );
  assert.equal(
    appendHandoffQuote(
      { kind: "text", text: "x".repeat(maxComposerTextBytes) },
      "quote",
    ).kind,
    "too_long",
  );
});

test("only reply links inside the task workspace enter the picker", () => {
  const task = {
    id: "3",
    inputSubmissions: [],
    runs: [
      {
        id: "1",
        submittedAtUnixMs: null,
        outputs: [],
        input: { kind: "text" },
        output: {
          commentary: [],
          responseKind: "final",
          response:
            "[PDF](reports/one.pdf) [External](https://example.org/doc.pdf) [Outside](../private.pdf)",
        },
      },
    ],
  };
  const files = conversationFiles(task, {
    id: "2",
    epoch: "1",
    canonicalRoot: "/project",
  });
  assert.deepEqual(
    files.map((f) => f.path),
    ["reports/one.pdf"],
  );
  assert.equal(files[0].source.target.kind, "workspace");
});

test("a conversation file joins only the draft of its own Task", () => {
  const upload = {
    key: "upload",
    name: "quote.xlsx",
    time: null,
    available: true,
    source: {
      kind: "message_file",
      attachment: {
        kind: "messageAttachment",
        taskId: "3",
        message: { kind: "run", runId: "7" },
        index: 0,
      },
    },
  };
  const draft = {
    allowed: true,
    task: { id: "3" },
    workspaces: [],
    current: true,
    scope: "task:3",
  };
  assert.equal(conversationFileReferable(upload, draft), true);
  // Another Task is open now: its draft never receives this Task's file.
  assert.equal(
    conversationFileReferable(upload, {
      ...draft,
      task: { id: "4" },
      scope: "task:4",
    }),
    false,
  );
  assert.equal(
    conversationFileReferable(upload, { ...draft, scope: "task:4" }),
    false,
  );
  for (const change of [{ allowed: false }, { current: false }, { task: null }])
    assert.equal(
      conversationFileReferable(upload, { ...draft, ...change }),
      false,
    );
  assert.equal(
    conversationFileReferable({ ...upload, available: false }, draft),
    false,
  );
});

test("a reply is parsed for file mentions again only when its text or names change", () => {
  const reply = (response) => ({
    id: "7",
    output: { commentary: [], response, responseKind: "final" },
  });
  const aliases = new Map([["reports/q.xlsx", { id: "r" }]]);
  const first = replyMentions("3", reply("See reports/q.xlsx"), aliases, true);
  assert.deepEqual(first, [["reference", "reports/q.xlsx"]]);
  // The next snapshot delivers the same reply as new objects.
  assert.equal(
    replyMentions("3", reply("See reports/q.xlsx"), new Map(aliases), true),
    first,
  );
  assert.notEqual(
    replyMentions("3", reply("See reports/q.xlsx again"), aliases, true),
    first,
  );
  assert.deepEqual(
    replyMentions("3", reply("See reports/q.xlsx"), new Map(), true),
    [],
  );
  // Another Task starts afresh.
  const other = replyMentions("4", reply("See reports/q.xlsx"), aliases, true);
  assert.deepEqual(other, first);
  assert.notEqual(other, first);
});
