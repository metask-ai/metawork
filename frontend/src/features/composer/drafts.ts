import {
  draftWithoutAttachments,
  emptyComposerDraft,
  parseSlashInput,
  composerDraftWithinLimits,
  maxComposerCharacters,
  maxSkillArguments,
  maxSkillRunInputBytes,
  type ComposerDraft,
  type ComposerSkillDraft,
} from "./slash.ts";

// Drafts are local Composer state, never part of the Host projection.
const legacyTaskPrefix = "metawork.task-draft.";
const taskPrefix = "metawork.task-draft.v1.";
const newTaskPrefix = "metawork.new-task-project-draft.v1.";
export const unscopedNewTaskDraftId = "unscoped";
export { maxComposerCharacters };
// Keep oversized text drafts editable across reloads, including JSON escaping.
const maxPersistedDraftBytes = 8 * 1024 * 1024;
const maxPersistedDraftSemanticBytes =
  maxSkillRunInputBytes + maxSkillRunInputBytes;

/** Per-message allowance; other drafts and shared resource usage do not enter it. */
export function remainingAttachmentFiles(
  draft: ComposerDraft,
  maxFiles: string,
): number {
  const count = draft.kind === "multimodal" ? draft.attachments.length : 0;
  const remaining = BigInt(maxFiles) - BigInt(count);
  if (remaining <= 0n) return 0;
  return Number(remaining > 0xffff_ffffn ? 0xffff_ffffn : remaining);
}

export function newTaskDraftStorageId(
  active: boolean,
  projectId: string | null,
) {
  return active ? projectId || unscopedNewTaskDraftId : null;
}

export function newTaskDraftMoveDecision(
  source: ComposerDraft,
  target: ComposerDraft,
  sourceHasDirectory = false,
  targetHasDirectory = false,
) {
  if (!draftHasContent(source) && !sourceHasDirectory)
    return "preserve_target" as const;
  if (draftHasContent(target) || targetHasDirectory)
    return "preserve_both" as const;
  return "move" as const;
}

export function prepareRetryDraft(
  currentDraft: ComposerDraft,
  instruction: string,
): {
  draft: ComposerDraft;
  kind: "prepared" | "preserved" | "too_long";
} {
  if (draftHasContent(currentDraft))
    return { draft: currentDraft, kind: "preserved" };
  if (!composerDraftWithinLimits({ kind: "text", text: instruction }))
    return { draft: currentDraft, kind: "too_long" };
  return {
    draft: { kind: "text", text: instruction },
    kind: "prepared",
  };
}

// A visible, editable instruction reference in the existing Task input. This
// does not create an attachment, locator grant or automatic model submission.
export function prepareOutputEditDraft(
  currentDraft: ComposerDraft,
  referenceLine: string,
): {
  draft: ComposerDraft;
  kind: "prepared" | "preserved" | "too_long";
} {
  if (
    currentDraft.kind === "skill" ||
    (currentDraft.kind === "text" && parseSlashInput(currentDraft.text))
  )
    return { draft: currentDraft, kind: "preserved" };
  const text =
    currentDraft.text === referenceLine ||
    currentDraft.text.startsWith(`${referenceLine}\n`)
      ? currentDraft.text
      : `${referenceLine}\n${currentDraft.text}`;
  const draft = { ...currentDraft, text };
  if (!composerDraftWithinLimits(draft))
    return { draft: currentDraft, kind: "too_long" };
  return { draft, kind: "prepared" };
}

function draftHasContent(draft: ComposerDraft) {
  return (
    draft.kind === "skill" ||
    draft.text.trim().length > 0 ||
    (draft.kind === "multimodal" && draft.attachments.length > 0)
  );
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return (
    actual.length === keys.length &&
    actual.every((key, index) => key === expected[index])
  );
}

function utf8ByteLength(value: string) {
  return new TextEncoder().encode(value).byteLength;
}

function boundedNonEmptyString(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maxSkillRunInputBytes
  );
}

function skillDraftPersistable(draft: ComposerSkillDraft) {
  if (
    (draft.skillPolicyKey !== undefined &&
      !boundedNonEmptyString(draft.skillPolicyKey)) ||
    !boundedNonEmptyString(draft.skillId) ||
    !boundedNonEmptyString(draft.invocationName) ||
    !boundedNonEmptyString(draft.displayName) ||
    !boundedNonEmptyString(draft.catalogRevision) ||
    !boundedNonEmptyString(draft.selectionRevision) ||
    !Number.isInteger(draft.maxValues) ||
    draft.maxValues < 0 ||
    draft.maxValues > maxSkillArguments ||
    draft.argumentNames.length > draft.maxValues ||
    draft.argumentValues.length > maxSkillArguments ||
    !draft.argumentNames.every(boundedNonEmptyString) ||
    !draft.argumentValues.every(
      (value) => value.length <= maxComposerCharacters,
    )
  )
    return false;
  let semanticBytes = 0;
  for (const value of [
    draft.skillId,
    draft.skillPolicyKey ?? "",
    draft.invocationName,
    draft.displayName,
    draft.catalogRevision,
    ...draft.argumentNames,
    ...draft.argumentValues,
  ]) {
    semanticBytes += utf8ByteLength(value);
    if (semanticBytes > maxPersistedDraftSemanticBytes) return false;
  }
  return true;
}

function decodeSkillDraft(
  draft: Record<string, unknown>,
): ComposerDraft | null {
  if (
    !exactKeys(draft, [
      ...(draft.skillPolicyKey === undefined ? [] : ["skillPolicyKey"]),
      ...(draft.attachmentsReloadRequired === undefined
        ? []
        : ["attachmentsReloadRequired"]),
      "kind",
      "skillId",
      "invocationName",
      "displayName",
      "catalogRevision",
      "selectionRevision",
      "argumentNames",
      "argumentValues",
      "maxValues",
    ]) ||
    draft.kind !== "skill" ||
    (draft.attachmentsReloadRequired !== undefined &&
      draft.attachmentsReloadRequired !== true) ||
    (draft.skillPolicyKey !== undefined &&
      !boundedNonEmptyString(draft.skillPolicyKey)) ||
    !boundedNonEmptyString(draft.skillId) ||
    !boundedNonEmptyString(draft.invocationName) ||
    !boundedNonEmptyString(draft.displayName) ||
    !boundedNonEmptyString(draft.catalogRevision) ||
    !boundedNonEmptyString(draft.selectionRevision) ||
    !Number.isInteger(draft.maxValues) ||
    (draft.maxValues as number) < 0 ||
    (draft.maxValues as number) > maxSkillArguments ||
    !Array.isArray(draft.argumentNames) ||
    !Array.isArray(draft.argumentValues)
  )
    return null;
  const maxValues = draft.maxValues as number;
  if (
    draft.argumentNames.length > maxValues ||
    draft.argumentValues.length > maxSkillArguments ||
    !draft.argumentNames.every(boundedNonEmptyString) ||
    !draft.argumentValues.every(
      (value) =>
        typeof value === "string" && value.length <= maxComposerCharacters,
    )
  )
    return null;
  const decoded: ComposerSkillDraft = {
    kind: "skill",
    skillId: draft.skillId,
    ...(draft.skillPolicyKey === undefined
      ? {}
      : { skillPolicyKey: draft.skillPolicyKey as string }),
    invocationName: draft.invocationName,
    displayName: draft.displayName,
    catalogRevision: draft.catalogRevision,
    selectionRevision: draft.selectionRevision,
    argumentNames: draft.argumentNames,
    argumentValues: draft.argumentValues,
    maxValues,
    ...(draft.attachmentsReloadRequired === true
      ? { attachmentsReloadRequired: true as const }
      : {}),
  };
  return skillDraftPersistable(decoded) ? decoded : null;
}

export function composerSessionStorage(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function decodeTaggedDraft(value: string | null): ComposerDraft {
  if (!value) return emptyComposerDraft();
  if (utf8ByteLength(value) > maxPersistedDraftBytes)
    return emptyComposerDraft();
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!parsed || typeof parsed !== "object") return emptyComposerDraft();
    const draft = parsed as Record<string, unknown>;
    if (
      draft.kind === "text" &&
      (exactKeys(draft, ["kind", "text"]) ||
        exactKeys(draft, ["kind", "text", "attachmentsReloadRequired"])) &&
      typeof draft.text === "string" &&
      (draft.attachmentsReloadRequired === undefined ||
        draft.attachmentsReloadRequired === true)
    )
      return {
        kind: "text",
        text: draft.text,
        ...(draft.attachmentsReloadRequired === true
          ? { attachmentsReloadRequired: true as const }
          : {}),
      };
    const skill = decodeSkillDraft(draft);
    if (skill) return skill;
  } catch {
    // Malformed tagged local data is not authoritative.
  }
  return emptyComposerDraft();
}

function decodeLegacyTextDraft(value: string | null): ComposerDraft {
  if (!value || utf8ByteLength(value) > maxPersistedDraftBytes)
    return emptyComposerDraft();
  return { kind: "text", text: value };
}

function encodeDraft(draft: ComposerDraft): string | null {
  // Attachment grants never outlive the connection: an attachment draft is
  // kept as its text, or its Skill draft, marked for re-choosing the files.
  const value =
    draft.kind === "multimodal" ? draftWithoutAttachments(draft, true) : draft;
  if (value.kind === "skill" && !skillDraftPersistable(value)) return null;
  const encoded = JSON.stringify(value);
  return utf8ByteLength(encoded) <= maxPersistedDraftBytes ? encoded : null;
}

function writeDraftValue(
  target: Storage,
  key: string,
  legacyKey: string,
  value: ComposerDraft,
): void {
  if (!draftHasContent(value)) {
    target.removeItem(key);
    target.removeItem(legacyKey);
    return;
  }
  const encoded = encodeDraft(value);
  if (encoded) {
    target.setItem(key, encoded);
    target.removeItem(legacyKey);
  }
}

export function readTaskDraft(taskId: string): ComposerDraft {
  try {
    const target = composerSessionStorage();
    if (!target) return emptyComposerDraft();
    const tagged = target.getItem(`${taskPrefix}${taskId}`);
    return tagged !== null
      ? decodeTaggedDraft(tagged)
      : decodeLegacyTextDraft(target.getItem(`${legacyTaskPrefix}${taskId}`));
  } catch {
    return emptyComposerDraft();
  }
}

const versionPrefix = "metawork.task-draft-version.v1.";
export function newComposerOperationId(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}
export function writeTaskDraft(taskId: string, value: ComposerDraft): void {
  try {
    const target = composerSessionStorage();
    if (!target) return;
    writeDraftValue(
      target,
      `${taskPrefix}${taskId}`,
      `${legacyTaskPrefix}${taskId}`,
      value,
    );
  } catch {
    // A local draft is helpful, but storage policy must not break the Composer.
  }
}

export function clearTaskDraft(taskId: string): void {
  writeTaskDraft(taskId, emptyComposerDraft());
}

export type NewTaskDirectory =
  | { kind: "project_default" }
  | { kind: "explicit"; workspaceId: string | null };
export type NewTaskDraftRecord = {
  directory: NewTaskDirectory;
  content: ComposerDraft;
};
export function readNewTaskDraftRecord(projectKey: string): NewTaskDraftRecord {
  const empty = (): NewTaskDraftRecord => ({
    directory: { kind: "project_default" },
    content: emptyComposerDraft(),
  });
  try {
    const encoded = composerSessionStorage()?.getItem(
      `${newTaskPrefix}${projectKey}`,
    );
    if (!encoded || utf8ByteLength(encoded) > maxPersistedDraftBytes)
      return empty();
    const value: unknown = JSON.parse(encoded);
    if (
      !value ||
      typeof value !== "object" ||
      !exactKeys(value as Record<string, unknown>, ["directory", "content"])
    )
      return empty();
    const record = value as Record<string, unknown>;
    const directory = record.directory as Record<string, unknown> | null;
    if (!directory || typeof directory !== "object") return empty();
    if (directory.kind === "project_default") {
      if (!exactKeys(directory, ["kind"])) return empty();
    } else if (directory.kind === "explicit") {
      if (!exactKeys(directory, ["kind", "workspaceId"])) return empty();
      const id = directory.workspaceId;
      if (
        id !== null &&
        (typeof id !== "string" ||
          !/^[1-9][0-9]{0,19}$/.test(id) ||
          BigInt(id) > 18446744073709551615n)
      )
        return empty();
    } else return empty();
    return {
      directory: directory as NewTaskDirectory,
      content: decodeTaggedDraft(JSON.stringify(record.content)),
    };
  } catch {
    return empty();
  }
}
export function writeNewTaskDraftRecord(
  projectKey: string,
  value: NewTaskDraftRecord,
): void {
  try {
    const target = composerSessionStorage();
    if (!target) return;
    const key = `${newTaskPrefix}${projectKey}`;
    if (
      !draftHasContent(value.content) &&
      value.directory.kind === "project_default"
    ) {
      target.removeItem(key);
      return;
    }
    const content = encodeDraft(value.content);
    if (content === null) return;
    const encoded = JSON.stringify({
      directory: value.directory,
      content: JSON.parse(content),
    });
    if (utf8ByteLength(encoded) <= maxPersistedDraftBytes)
      target.setItem(key, encoded);
  } catch {
    /* Local draft storage must not prevent composing. */
  }
}
export function readNewTaskDraft(projectKey: string): ComposerDraft {
  return readNewTaskDraftRecord(projectKey).content;
}
export function writeNewTaskDraft(
  projectKey: string,
  value: ComposerDraft,
): void {
  writeNewTaskDraftRecord(projectKey, {
    directory: readNewTaskDraftRecord(projectKey).directory,
    content: value,
  });
}
export function clearNewTaskDraft(projectKey: string): void {
  writeNewTaskDraft(projectKey, emptyComposerDraft());
}

export function pruneTaskDrafts(validTaskIds: ReadonlySet<string>): void {
  try {
    const target = composerSessionStorage();
    if (!target) return;
    const stale: string[] = [];
    for (let index = 0; index < target.length; index += 1) {
      const key = target.key(index);
      if (!key) continue;
      const taskId = key.startsWith(versionPrefix)
        ? key.slice(versionPrefix.length)
        : key.startsWith(taskPrefix)
          ? key.slice(taskPrefix.length)
          : key.startsWith(legacyTaskPrefix)
            ? key.slice(legacyTaskPrefix.length)
            : null;
      if (taskId !== null && !validTaskIds.has(taskId)) stale.push(key);
    }
    for (const key of stale) target.removeItem(key);
  } catch {
    // Storage cleanup follows the same fail-safe policy as draft persistence.
  }
}
