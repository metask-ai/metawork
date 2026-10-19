import {
  emptyComposerDraft,
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
const legacyNewTaskPrefix = "metawork.new-task-draft.";
const newTaskPrefix = "metawork.new-task-draft.v1.";
export const unscopedNewTaskDraftId = "unscoped";
export { maxComposerCharacters };
// Keep oversized text drafts editable across reloads, including JSON escaping.
const maxPersistedDraftBytes = 8 * 1024 * 1024;
const maxPersistedDraftSemanticBytes =
  maxSkillRunInputBytes + maxSkillRunInputBytes;

export function newTaskDraftStorageId(
  active: boolean,
  workspaceId: string | null,
) {
  return active ? workspaceId || unscopedNewTaskDraftId : null;
}

export function newTaskDraftMoveDecision(
  source: ComposerDraft,
  target: ComposerDraft,
) {
  if (!draftHasContent(source)) return "preserve_target" as const;
  if (draftHasContent(target)) return "preserve_both" as const;
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
    !boundedNonEmptyString(draft.skillId) ||
    !boundedNonEmptyString(draft.invocationName) ||
    !boundedNonEmptyString(draft.displayName) ||
    !boundedNonEmptyString(draft.catalogRevision) ||
    !boundedNonEmptyString(draft.selectionRevision) ||
    !Number.isInteger(draft.maxValues) ||
    draft.maxValues < 0 ||
    draft.maxValues > maxSkillArguments ||
    draft.argumentNames.length > draft.maxValues ||
    draft.argumentValues.length > draft.maxValues ||
    !draft.argumentNames.every(boundedNonEmptyString) ||
    !draft.argumentValues.every(
      (value) => value.length <= maxComposerCharacters,
    )
  )
    return false;
  let semanticBytes = 0;
  for (const value of [
    draft.skillId,
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
    draft.argumentValues.length > maxValues ||
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
    invocationName: draft.invocationName,
    displayName: draft.displayName,
    catalogRevision: draft.catalogRevision,
    selectionRevision: draft.selectionRevision,
    argumentNames: draft.argumentNames,
    argumentValues: draft.argumentValues,
    maxValues,
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

function encodeDraft(value: ComposerDraft): string | null {
  if (value.kind === "multimodal") {
    const encoded = JSON.stringify({
      kind: "text",
      text: value.text,
      attachmentsReloadRequired: true,
    });
    return utf8ByteLength(encoded) <= maxPersistedDraftBytes ? encoded : null;
  }
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

export function readNewTaskDraft(workspaceId: string): ComposerDraft {
  try {
    const target = composerSessionStorage();
    if (!target) return emptyComposerDraft();
    const tagged = target.getItem(`${newTaskPrefix}${workspaceId}`);
    return tagged !== null
      ? decodeTaggedDraft(tagged)
      : decodeLegacyTextDraft(
          target.getItem(`${legacyNewTaskPrefix}${workspaceId}`),
        );
  } catch {
    return emptyComposerDraft();
  }
}

export function writeNewTaskDraft(
  workspaceId: string,
  value: ComposerDraft,
): void {
  try {
    const target = composerSessionStorage();
    if (!target) return;
    writeDraftValue(
      target,
      `${newTaskPrefix}${workspaceId}`,
      `${legacyNewTaskPrefix}${workspaceId}`,
      value,
    );
  } catch {
    // Draft persistence is helpful, but never a prerequisite for composing.
  }
}

export function clearNewTaskDraft(workspaceId: string): void {
  writeNewTaskDraft(workspaceId, emptyComposerDraft());
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
