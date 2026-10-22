import assert from "node:assert/strict";
import test from "node:test";
import { prepareOutputEditDraft } from "../frontend/src/features/composer/drafts.ts";
import {
  composerDraftToRunInput,
  maxComposerTextBytes,
} from "../frontend/src/features/composer/slash.ts";
const reference =
  'Continue editing the Workspace file "results/年度报告.docx":';
test("Continue editing creates an editable reference and preserves the user's current instruction", () => {
  const original = { kind: "text", text: "Make the heading blue" };
  const prepared = prepareOutputEditDraft(original, reference);
  assert.equal(prepared.kind, "prepared");
  assert.equal(prepared.draft.text, reference + "\nMake the heading blue");
  assert.deepEqual(original, { kind: "text", text: "Make the heading blue" });
  assert.deepEqual(composerDraftToRunInput(prepared.draft), {
    kind: "text",
    text: prepared.draft.text,
  });
  assert.equal(
    prepareOutputEditDraft(prepared.draft, reference).draft.text,
    prepared.draft.text,
  );
});
test("Continue editing keeps existing attachment tokens in their normal input flow", () => {
  const attachments = [
    {
      token: "owned-token",
      kind: "file",
      displayName: "reference.docx",
      sizeBytes: "12",
    },
  ];
  const prepared = prepareOutputEditDraft(
    { kind: "multimodal", text: "Match this template", attachments },
    reference,
  );
  assert.equal(prepared.kind, "prepared");
  assert.equal(prepared.draft.attachments, attachments);
  assert.deepEqual(composerDraftToRunInput(prepared.draft), {
    kind: "multimodal",
    text: reference + "\nMatch this template",
    attachmentTokens: ["owned-token"],
  });
  const reloaded = {
    kind: "text",
    text: "Draft",
    attachmentsReloadRequired: true,
  };
  assert.equal(
    prepareOutputEditDraft(reloaded, reference).draft.attachmentsReloadRequired,
    true,
  );
});
test("Continue editing does not rewrite Skill arguments or an unresolved slash command", () => {
  for (const draft of [
    { kind: "skill", argumentValues: ["keep my arguments"] },
    { kind: "text", text: "/docx update" },
  ]) {
    const prepared = prepareOutputEditDraft(draft, reference);
    assert.equal(prepared.kind, "preserved");
    assert.equal(prepared.draft, draft);
  }
});
test("Continue editing counts UTF-8 bytes and refuses overflow without truncating the draft", () => {
  const bytes = new TextEncoder().encode(reference + "\n").byteLength;
  const exact = {
    kind: "text",
    text: "x".repeat(maxComposerTextBytes - bytes),
  };
  assert.equal(prepareOutputEditDraft(exact, reference).kind, "prepared");
  const overflow = { kind: "text", text: exact.text + "中" };
  const rejected = prepareOutputEditDraft(overflow, reference);
  assert.equal(rejected.kind, "too_long");
  assert.equal(rejected.draft, overflow);
});
