import type { SkillCatalogView, TaskRunInput } from "../../bridge/contracts.ts";

export type ComposerTextDraft = {
  kind: "text";
  text: string;
  attachmentsReloadRequired?: true;
};

export type ComposerAttachment = {
  token: string;
  kind: "image";
  format: "png" | "jpeg" | "webp";
  displayName: string;
  sizeBytes: string;
};

export type ComposerMultimodalDraft = {
  kind: "multimodal";
  text: string;
  attachments: ComposerAttachment[];
};

export type ComposerSkillDraft = {
  kind: "skill";
  skillId: string;
  invocationName: string;
  displayName: string;
  catalogRevision: string;
  selectionRevision: string;
  argumentNames: string[];
  argumentValues: string[];
  maxValues: number;
};

export type ComposerDraft =
  ComposerTextDraft | ComposerSkillDraft | ComposerMultimodalDraft;

export const maxComposerCharacters = 16 * 1024;
export const maxSkillArguments = 64;
export const maxSkillRunInputBytes = 64 * 1024;

export const emptyComposerDraft = (): ComposerDraft => ({
  kind: "text",
  text: "",
});

export function composerDraftHasContent(draft: ComposerDraft) {
  return (
    draft.kind === "skill" ||
    draft.text.trim().length > 0 ||
    (draft.kind === "multimodal" && draft.attachments.length > 0)
  );
}

function utf8ByteLength(value: string) {
  return new TextEncoder().encode(value).byteLength;
}

export function composerDraftWithinLimits(draft: ComposerDraft) {
  if (draft.kind === "text" || draft.kind === "multimodal")
    return draft.text.length <= maxComposerCharacters;
  if (
    !Number.isInteger(draft.maxValues) ||
    draft.maxValues < 0 ||
    draft.maxValues > maxSkillArguments ||
    draft.argumentNames.length > draft.maxValues ||
    draft.argumentValues.length > draft.maxValues ||
    draft.argumentValues.some((value) => value.length > maxComposerCharacters)
  )
    return false;
  let bytes =
    utf8ByteLength(draft.skillId) +
    utf8ByteLength(draft.catalogRevision) +
    utf8ByteLength(draft.selectionRevision);
  for (const value of draft.argumentValues) {
    bytes += utf8ByteLength(value);
    if (bytes > maxSkillRunInputBytes) return false;
  }
  return bytes <= maxSkillRunInputBytes;
}

export function composerDraftToRunInput(
  draft: ComposerDraft,
): TaskRunInput | null {
  if (draft.kind === "text")
    return parseSlashInput(draft.text)
      ? null
      : { kind: "text", text: draft.text };
  if (draft.kind === "multimodal")
    return draft.attachments.length === 0 || parseSlashInput(draft.text)
      ? null
      : {
          kind: "multimodal",
          text: draft.text,
          attachmentTokens: draft.attachments.map(
            (attachment) => attachment.token,
          ),
        };
  return {
    kind: "skill",
    skillId: draft.skillId,
    catalogRevision: draft.catalogRevision,
    selectionRevision: draft.selectionRevision,
    argumentValues: draft.argumentValues,
  };
}

export function isSkillDraftCurrent(
  draft: ComposerDraft,
  catalog: SkillCatalogView,
) {
  const descriptor =
    draft.kind === "skill"
      ? catalog.skills.find((skill) => skill.skillId === draft.skillId)
      : null;
  return (
    draft.kind === "skill" &&
    (catalog.availability === "ready" || catalog.availability === "degraded") &&
    catalog.revision === draft.catalogRevision &&
    catalog.selectionRevision === draft.selectionRevision &&
    descriptor != null &&
    descriptor.enabled &&
    Math.min(descriptor.maxValues, maxSkillArguments) === draft.maxValues
  );
}

export function skillCatalogRefreshTarget(
  hasTask: boolean,
  workspaceCatalog: SkillCatalogView,
) {
  return hasTask &&
    (workspaceCatalog.availability === "ready" ||
      workspaceCatalog.availability === "degraded")
    ? ("task" as const)
    : ("workspace" as const);
}

export function skillDraftVisibleArgumentCount(draft: ComposerSkillDraft) {
  return Math.min(
    draft.maxValues,
    Math.max(
      draft.argumentNames.length,
      draft.argumentValues.length,
      draft.argumentNames.length === 0 && draft.maxValues > 0 ? 1 : 0,
    ),
  );
}

export const slashCommandNames = ["new", "compact"] as const;

export type SlashCommandName = (typeof slashCommandNames)[number];

export type SlashCommandDisabledReason =
  "already_new_task" | "task_busy" | "no_history" | "unavailable";

export type SlashCommandState = {
  name: SlashCommandName;
  enabled: boolean;
  disabledReason: SlashCommandDisabledReason | null;
};

export type SlashCommandContext = {
  newTaskDraftActive: boolean;
  bridgeUnavailable: boolean;
  taskMutationDisabled: boolean;
  task: {
    lifecycleOpen: boolean;
    continuationAvailable: boolean;
    archived: boolean;
    activeOperation: boolean;
    hasFinalizedRun: boolean;
  } | null;
};

export function resolveSlashCommandStates({
  newTaskDraftActive,
  bridgeUnavailable,
  taskMutationDisabled,
  task,
}: SlashCommandContext): SlashCommandState[] {
  const newEnabled = !newTaskDraftActive && !bridgeUnavailable;
  const compactEnabled = Boolean(
    task &&
    !newTaskDraftActive &&
    !bridgeUnavailable &&
    !taskMutationDisabled &&
    task.lifecycleOpen &&
    task.continuationAvailable &&
    !task.archived &&
    !task.activeOperation &&
    task.hasFinalizedRun,
  );

  return slashCommandNames.map((name) => {
    if (name === "new")
      return {
        name,
        enabled: newEnabled,
        disabledReason: newEnabled
          ? null
          : newTaskDraftActive
            ? "already_new_task"
            : "unavailable",
      };
    return {
      name,
      enabled: compactEnabled,
      disabledReason: compactEnabled
        ? null
        : newTaskDraftActive
          ? "no_history"
          : task?.activeOperation
            ? "task_busy"
            : !task?.hasFinalizedRun
              ? "no_history"
              : "unavailable",
    };
  });
}

export type SlashCandidate =
  | {
      kind: "command";
      key: string;
      name: SlashCommandName;
      invocation: string;
      enabled: boolean;
      disabledReason: SlashCommandDisabledReason | null;
    }
  | {
      kind: "skill";
      key: string;
      skillId: string;
      invocationName: string;
      displayName: string;
      description: string;
      invocation: string;
      argumentNames: string[];
      maxValues: number;
      catalogRevision: string;
      selectionRevision: string;
      tail: string;
      enabled: boolean;
      disabledReason: string | null;
    };

export type SlashInput = {
  query: string;
  tail: string;
  explicitSkill: boolean;
};

export function parseSlashInput(text: string): SlashInput | null {
  const match = text.match(/^\s*\/(\S*)(?:\s+([\s\S]*))?$/);
  if (!match) return null;
  const token = match[1] ?? "";
  if (token.includes("/")) return null;
  if (token.toLocaleLowerCase().startsWith("skill:"))
    return {
      query: token.slice("skill:".length),
      tail: match[2] ?? "",
      explicitSkill: true,
    };
  return {
    query: token,
    tail: match[2] ?? "",
    explicitSkill: false,
  };
}

function matches(query: string, value: string) {
  const normalizedQuery = query.toLowerCase();
  const normalizedValue = value.toLowerCase();
  return (
    normalizedValue.startsWith(normalizedQuery) ||
    normalizedValue.includes(normalizedQuery)
  );
}

export function resolveSlashCandidates({
  input,
  commands,
  catalog,
  skillsOnly = false,
}: {
  input: SlashInput;
  commands: readonly SlashCommandState[];
  catalog: SkillCatalogView;
  skillsOnly?: boolean;
}): SlashCandidate[] {
  const candidates: SlashCandidate[] = [];
  const commandNames = new Set(commands.map((command) => command.name));
  if (!input.explicitSkill && !skillsOnly) {
    for (const command of commands) {
      if (!matches(input.query, command.name)) continue;
      if (input.tail.length > 0) continue;
      candidates.push({
        kind: "command",
        key: `command:${command.name}`,
        name: command.name,
        invocation: `/${command.name}`,
        enabled: command.enabled,
        disabledReason: command.disabledReason,
      });
    }
  }

  if (catalog.availability !== "ready" && catalog.availability !== "degraded")
    return candidates;
  if (!catalog.revision || !catalog.selectionRevision) return candidates;

  for (const skill of catalog.skills) {
    if (!skill.enabled) continue;
    if (!matches(input.query, skill.invocationName)) continue;
    const collides = commandNames.has(skill.invocationName as SlashCommandName);
    if (!input.explicitSkill && collides) continue;
    const invocation =
      input.explicitSkill || collides
        ? `/skill:${skill.invocationName}`
        : `/${skill.invocationName}`;
    candidates.push({
      kind: "skill",
      key: `skill:${skill.skillId}`,
      skillId: skill.skillId,
      invocationName: skill.invocationName,
      displayName: skill.displayName,
      description: skill.description,
      invocation,
      argumentNames: skill.argumentNames,
      maxValues: skill.maxValues,
      catalogRevision: catalog.revision,
      selectionRevision: catalog.selectionRevision,
      tail: input.tail,
      enabled: true,
      disabledReason: null,
    });
  }
  return candidates;
}

export function skillDraftFromCandidate(
  candidate: Extract<SlashCandidate, { kind: "skill" }>,
): ComposerSkillDraft {
  const maxValues = Math.min(candidate.maxValues, maxSkillArguments);
  const valueCount = Math.max(
    Math.min(candidate.argumentNames.length, maxValues),
    candidate.tail && maxValues > 0 ? 1 : 0,
  );
  return {
    kind: "skill",
    skillId: candidate.skillId,
    invocationName: candidate.invocationName,
    displayName: candidate.displayName,
    catalogRevision: candidate.catalogRevision,
    selectionRevision: candidate.selectionRevision,
    argumentNames: candidate.argumentNames.slice(0, maxValues),
    argumentValues: Array.from({ length: valueCount }, (_, index) =>
      index === 0 ? candidate.tail : "",
    ),
    maxValues,
  };
}
