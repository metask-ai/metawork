import type {
  AttachmentDescriptor,
  FileTarget,
  SkillCatalogView,
  TaskActionBlocker,
  TaskRunInput,
} from "../../bridge/contracts.ts";

export type ComposerTextDraft = {
  kind: "text";
  text: string;
  attachmentsReloadRequired?: true;
};

export type ComposerAttachment = AttachmentDescriptor & {
  reference?: { key: string; detail: string; target?: FileTarget };
};

/** One exact Skill selection, as a Skill draft and an attachment draft hold it. */
export type ComposerSkillSelection = {
  // Older session drafts acquire this only from an exact valid selection.
  skillPolicyKey?: string;
  skillId: string;
  invocationName: string;
  displayName: string;
  catalogRevision: string;
  selectionRevision: string;
  argumentNames: string[];
  maxValues: number;
};

export type ComposerMultimodalDraft = {
  kind: "multimodal";
  text: string;
  attachments: ComposerAttachment[];
  /** The Skill selected for this message, sent with the attachments (#201). */
  skill: ComposerSkillSelection | null;
};

export type ComposerSkillDraft = { kind: "skill" } & ComposerSkillSelection & {
    argumentValues: string[];
    /** The attachments sent with this Skill were lost and must be re-chosen. */
    attachmentsReloadRequired?: true;
  };

export type ComposerDraft =
  ComposerTextDraft | ComposerSkillDraft | ComposerMultimodalDraft;

export const maxComposerCharacters = 16 * 1024; // Structured Skill arguments.
export const maxComposerTextBytes = 256 * 1024;
export const maxSkillArguments = 64;
export const maxSkillRunInputBytes = 64 * 1024;

export const emptyComposerDraft = (): ComposerDraft => ({
  kind: "text",
  text: "",
});

export function composerDraftHasContent(draft: ComposerDraft) {
  if (draft.kind === "skill") return true;
  if (draft.text.trim().length > 0) return true;
  return (
    draft.kind === "multimodal" &&
    draft.attachments.length > 0 &&
    !draft.attachments.some((attachment) => attachment.kind === "file")
  );
}

function utf8ByteLength(value: string) {
  return new TextEncoder().encode(value).byteLength;
}

export function composerDraftWithinLimits(draft: ComposerDraft) {
  if (draft.kind === "text" || draft.kind === "multimodal")
    return utf8ByteLength(draft.text) <= maxComposerTextBytes;
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
    return draft.attachments.length === 0 ||
      (draft.attachments.some((attachment) => attachment.kind === "file") &&
        draft.text.trim().length === 0) ||
      (draft.skill === null && parseSlashInput(draft.text))
      ? null
      : {
          kind: "multimodal",
          text: draft.text,
          attachmentTokens: draft.attachments.map(
            (attachment) => attachment.token,
          ),
          skill: draft.skill && {
            skillId: draft.skill.skillId,
            catalogRevision: draft.skill.catalogRevision,
            selectionRevision: draft.skill.selectionRevision,
          },
        };
  return {
    kind: "skill",
    skillId: draft.skillId,
    catalogRevision: draft.catalogRevision,
    selectionRevision: draft.selectionRevision,
    argumentValues: draft.argumentValues,
  };
}

/** The exact Skill selection a Run input makes, if any. */
export function runInputSkill(
  input: TaskRunInput,
): { catalogRevision: string; selectionRevision: string } | null {
  if (input.kind === "skill") return input;
  return input.kind === "multimodal" ? input.skill : null;
}

/** The Skill a draft has selected, with or without attachments. */
export function draftSkillSelection(
  draft: ComposerDraft,
): ComposerSkillSelection | null {
  if (draft.kind === "multimodal") return draft.skill;
  if (draft.kind !== "skill") return null;
  return {
    ...(draft.skillPolicyKey === undefined
      ? {}
      : { skillPolicyKey: draft.skillPolicyKey }),
    skillId: draft.skillId,
    invocationName: draft.invocationName,
    displayName: draft.displayName,
    catalogRevision: draft.catalogRevision,
    selectionRevision: draft.selectionRevision,
    argumentNames: draft.argumentNames,
    maxValues: draft.maxValues,
  };
}

/** The body the Composer shows: a Skill draft's values read as one text. */
export function composerDraftText(draft: ComposerDraft) {
  return draft.kind === "skill" ? draft.argumentValues.join("\n") : draft.text;
}

/**
 * Adds attachments to any draft. A Skill draft keeps its selection and its
 * body becomes the message text exactly as the Composer shows it; with
 * attachments the text is the user's message, not Skill arguments.
 */
export function draftWithAttachments(
  draft: ComposerDraft,
  attachments: ComposerAttachment[],
): ComposerMultimodalDraft {
  if (draft.kind === "multimodal")
    return { ...draft, attachments: [...draft.attachments, ...attachments] };
  return {
    kind: "multimodal",
    text: composerDraftText(draft),
    attachments,
    skill: draftSkillSelection(draft),
  };
}

/**
 * The draft once its attachments are gone: removed by the user, or lost to a
 * reload or reconnect, which `reloadRequired` records so the Composer can say
 * so. A selected Skill becomes a Skill draft again, its text one value.
 */
export function draftWithoutAttachments(
  draft: ComposerMultimodalDraft,
  reloadRequired: boolean,
): ComposerDraft {
  const marker = reloadRequired
    ? { attachmentsReloadRequired: true as const }
    : {};
  return draft.skill
    ? {
        kind: "skill",
        ...draft.skill,
        argumentValues: draft.text ? [draft.text] : [],
        ...marker,
      }
    : { kind: "text", text: draft.text, ...marker };
}

/** Removes the selected Skill and keeps the text and any attachments. */
export function draftWithoutSkill(draft: ComposerDraft): ComposerDraft {
  if (draft.kind === "multimodal") return { ...draft, skill: null };
  return { kind: "text", text: composerDraftText(draft) };
}

function selectedSkill(
  draft: ComposerSkillSelection,
  catalog: SkillCatalogView,
) {
  if (catalog.availability !== "ready" && catalog.availability !== "degraded")
    return undefined;
  return draft.skillPolicyKey
    ? catalog.skills.find(
        (skill) => skill.skillPolicyKey === draft.skillPolicyKey,
      )
    : catalog.revision === draft.catalogRevision &&
        catalog.selectionRevision === draft.selectionRevision
      ? catalog.skills.find((skill) => skill.skillId === draft.skillId)
      : undefined;
}

function sameArguments(
  draft: ComposerSkillSelection,
  skill: SkillCatalogView["skills"][number],
) {
  return (
    draft.maxValues === Math.min(skill.maxValues, maxSkillArguments) &&
    draft.argumentNames.length === skill.argumentNames.length &&
    draft.argumentNames.every(
      (name, index) => name === skill.argumentNames[index],
    )
  );
}

function bindSkillDraft<Selection extends ComposerSkillSelection>(
  draft: Selection,
  skill: SkillCatalogView["skills"][number],
  catalog: SkillCatalogView,
): Selection {
  if (
    draft.skillId === skill.skillId &&
    draft.skillPolicyKey === skill.skillPolicyKey &&
    draft.catalogRevision === catalog.revision &&
    draft.selectionRevision === catalog.selectionRevision &&
    draft.displayName === skill.displayName &&
    draft.invocationName === skill.invocationName &&
    sameArguments(draft, skill)
  )
    return draft;
  return {
    ...draft,
    skillId: skill.skillId,
    skillPolicyKey: skill.skillPolicyKey,
    invocationName: skill.invocationName,
    displayName: skill.displayName,
    catalogRevision: catalog.revision!,
    selectionRevision: catalog.selectionRevision!,
    argumentNames: [...skill.argumentNames],
    maxValues: Math.min(skill.maxValues, maxSkillArguments),
  };
}

export function reconcileSkillDraft(
  draft: ComposerDraft,
  catalog: SkillCatalogView,
): ComposerDraft {
  if (draft.kind === "multimodal") {
    if (!draft.skill) return draft;
    // No arguments travel with attachments, so their definition never
    // holds a selection back.
    const skill = selectedSkill(draft.skill, catalog);
    if (!skill?.enabled) return draft;
    const bound = bindSkillDraft(draft.skill, skill, catalog);
    return bound === draft.skill ? draft : { ...draft, skill: bound };
  }
  if (draft.kind !== "skill") return draft;
  const skill = selectedSkill(draft, catalog);
  return skill?.enabled && sameArguments(draft, skill)
    ? bindSkillDraft(draft, skill, catalog)
    : draft;
}

export function skillDraftProblem(
  draft: ComposerSkillDraft,
  catalog: SkillCatalogView,
) {
  return skillSelectionProblem(draft, catalog, true);
}

/**
 * Why a selection cannot be sent. Argument definitions matter only to a
 * Skill draft, whose text is the Skill's arguments.
 */
export function skillSelectionProblem(
  selection: ComposerSkillSelection,
  catalog: SkillCatalogView,
  checkArguments: boolean,
) {
  if (catalog.availability !== "ready" && catalog.availability !== "degraded")
    return "catalog" as const;
  const skill = selectedSkill(selection, catalog);
  if (!skill) return "missing" as const;
  if (!skill.enabled) return "disabled" as const;
  return !checkArguments || sameArguments(selection, skill)
    ? null
    : ("arguments" as const);
}

/** The draft's Skill problem, if it selects one. */
export function draftSkillProblem(
  draft: ComposerDraft,
  catalog: SkillCatalogView,
) {
  if (draft.kind === "skill") return skillDraftProblem(draft, catalog);
  if (draft.kind === "multimodal" && draft.skill)
    return skillSelectionProblem(draft.skill, catalog, false);
  return null;
}

// Explicitly open the new parameter definition for review, retaining all text.
// Surplus values stay visible and must be removed before sending.
export function reviewSkillDraft(
  draft: ComposerSkillDraft,
  catalog: SkillCatalogView,
): ComposerSkillDraft {
  const skill = selectedSkill(draft, catalog);
  return skill?.enabled ? bindSkillDraft(draft, skill, catalog) : draft;
}

export function isSkillDraftCurrent(
  draft: ComposerDraft,
  catalog: SkillCatalogView,
) {
  return (
    draftSkillSelection(draft) !== null &&
    draftSkillProblem(draft, catalog) === null
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
  task: { compactBlocker: TaskActionBlocker | null } | null;
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
    task.compactBlocker === null,
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
        : newTaskDraftActive || !task || task.compactBlocker === "no_history"
          ? "no_history"
          : task.compactBlocker === "busy"
            ? "task_busy"
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
      skillPolicyKey: string;
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
      skillPolicyKey: skill.skillPolicyKey,
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

function skillSelectionFromCandidate(
  candidate: Extract<SlashCandidate, { kind: "skill" }>,
): ComposerSkillSelection {
  const maxValues = Math.min(candidate.maxValues, maxSkillArguments);
  return {
    skillId: candidate.skillId,
    skillPolicyKey: candidate.skillPolicyKey,
    invocationName: candidate.invocationName,
    displayName: candidate.displayName,
    catalogRevision: candidate.catalogRevision,
    selectionRevision: candidate.selectionRevision,
    argumentNames: candidate.argumentNames.slice(0, maxValues),
    maxValues,
  };
}

export function skillDraftFromCandidate(
  candidate: Extract<SlashCandidate, { kind: "skill" }>,
): ComposerSkillDraft {
  return {
    kind: "skill",
    ...skillSelectionFromCandidate(candidate),
    argumentValues: candidate.tail ? [candidate.tail] : [],
  };
}

/**
 * Selects a Skill in the current draft. Attachments stay and the candidate's
 * tail becomes the message text; without attachments it is a Skill draft.
 */
export function draftWithSkillCandidate(
  draft: ComposerDraft,
  candidate: Extract<SlashCandidate, { kind: "skill" }>,
): ComposerDraft {
  return draft.kind === "multimodal"
    ? {
        ...draft,
        text: candidate.tail,
        skill: skillSelectionFromCandidate(candidate),
      }
    : skillDraftFromCandidate(candidate);
}
