import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
  type RefObject,
  type ReactNode,
} from "react";

import type { SkillCatalogView, TaskView } from "../../bridge/contracts.ts";
import { Composer } from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Input } from "../../components/ui/input.tsx";
import { Textarea } from "../../components/ui/textarea.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { maxComposerCharacters } from "./drafts.ts";
import { ModelSelector, type ModelSelectorOption } from "./ModelSelector.tsx";
import { SlashMenu } from "./SlashMenu.tsx";
import {
  composerDraftWithinLimits,
  emptyComposerDraft,
  isSkillDraftCurrent,
  reviewSkillDraft,
  skillDraftProblem,
  parseSlashInput,
  resolveSlashCandidates,
  skillDraftFromCandidate,
  skillDraftVisibleArgumentCount,
  type ComposerDraft,
  type ComposerAttachment,
  type ComposerSkillDraft,
  type SlashCandidate,
  type SlashCommandName,
  type SlashCommandState,
} from "./slash.ts";
import { WorkspaceContextSelector } from "./WorkspaceContextSelector.tsx";
import { useComposerKeyboard } from "./useComposerKeyboard.ts";

export type ComposerInputHistory = {
  load: () => Promise<readonly string[]>;
  currentDraft: () => ComposerDraft | null;
  commitDraft: (draft: ComposerDraft) => boolean;
};

function canEnterInputHistory(draft: ComposerDraft) {
  return (
    draft.kind === "text" &&
    draft.text === "" &&
    !draft.attachmentsReloadRequired
  );
}

function resizeComposerTextarea(textarea: HTMLTextAreaElement) {
  const maxHeight = Math.min(180, window.innerHeight * 0.28);
  textarea.style.height = "auto";
  textarea.style.height = `${Math.min(textarea.scrollHeight, maxHeight)}px`;
  textarea.style.overflowY =
    textarea.scrollHeight > maxHeight ? "auto" : "hidden";
}

function formatAttachmentSize(value: string) {
  const bytes = Number(value);
  if (!Number.isSafeInteger(bytes) || bytes <= 0) return value;
  if (bytes < 1_000) return `${bytes} B`;
  if (bytes < 1_000_000) return `${Math.ceil(bytes / 1_000)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function attachmentTypeLabel(
  attachment: ComposerAttachment,
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(
    attachment.kind === "image"
      ? "attachment.type.image"
      : "attachment.type.file",
  );
}

function attachmentErrorMessage(reason: string): MessageId {
  const messages: Record<string, MessageId> = {
    unsupported_type: "attachment.error.unsupported_type",
    file_too_large: "attachment.error.file_too_large",
    text_file_too_large: "attachment.error.file_too_large",
    too_many_files: "attachment.error.too_many_files",
    staging_capacity: "attachment.error.staging_capacity",
    read_failed: "attachment.error.read_failed",
    file_changed: "attachment.error.file_changed",
    shutting_down: "attachment.error.shutting_down",
    invalid_transfer: "attachment.error.invalid_transfer",
    stale_transfer: "attachment.error.stale_transfer",
    input_busy: "attachment.error.input_busy",
    input_unavailable: "attachment.error.input_unavailable",
    cleanup_failed: "attachment.error.cleanup_failed",
    release_unconfirmed: "attachment.error.release_unconfirmed",
  };
  return messages[reason] ?? "attachment.error.generic";
}

export function ComposerFooter({
  textareaRef,
  approvalModeControl,
  archived,
  closing,
  unavailable,
  unavailableReason,
  draft,
  draftScope = "",
  inputHistory,
  attachmentsEnabled,
  attachmentMaxFileBytes,
  attachmentBusy,
  attachmentActionsDisabled = false,
  attachmentCancelling = false,
  attachmentRemoving = false,
  attachmentError,
  attachmentModelWarning,
  skillCatalog,
  slashCommands,
  composeDisabled,
  canSubmit,
  runInFlight,
  accessRequired,
  workspaceLabel,
  workspaceTitle,
  workspaceDiagnostic,
  workspaceOptions,
  selectedWorkspaceOptionId,
  workspaceEditable,
  workspaceSelectionPending = false,
  modelLabel,
  modelTriggerRef,
  modelOptions,
  selectedModelId,
  modelEditable,
  modelSelectionDisabled,
  modelSelectionPending,
  modelContextTitle,
  modelNotice,
  actionDisabled,
  stopAction,
  stopDisabled,
  onDraftChange,
  onChooseAttachments,
  onDropFiles,
  onPasteImages,
  onCancelAttachments,
  onRemoveAttachment,
  onSubmit,
  sendDisabledReason,
  quietDraftChange = false,
  onStop,
  onSlashCommand,
  onRefreshSkillCatalog,
  onConfirmAccess,
  onSelectWorkspace,
  onSelectModel,
}: {
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  approvalModeControl?: ReactNode;
  archived: boolean;
  closing: boolean;
  unavailable: boolean;
  unavailableReason: TaskView["continuationUnavailableReason"];
  draft: ComposerDraft;
  draftScope?: string;
  inputHistory?: ComposerInputHistory;
  attachmentsEnabled: boolean;
  attachmentMaxFileBytes: string;
  attachmentBusy: boolean;
  attachmentActionsDisabled?: boolean;
  attachmentCancelling?: boolean;
  attachmentRemoving?: boolean;
  attachmentError: string | null;
  attachmentModelWarning: "image" | null;
  skillCatalog: SkillCatalogView;
  slashCommands: readonly SlashCommandState[];
  composeDisabled: boolean;
  canSubmit: boolean;
  runInFlight: boolean;
  accessRequired: boolean;
  workspaceLabel: string;
  workspaceTitle: string;
  workspaceDiagnostic?: string;
  workspaceOptions: {
    id: string;
    label: string;
    triggerLabel?: string;
    authorization: "available" | "removing" | "reauthorization_required";
    disabled?: boolean;
  }[];
  selectedWorkspaceOptionId: string;
  workspaceEditable: boolean;
  workspaceSelectionPending?: boolean;
  modelLabel: string | null;
  modelTriggerRef?: RefObject<HTMLButtonElement | null>;
  modelOptions: ModelSelectorOption[];
  selectedModelId: string;
  modelEditable: boolean;
  modelSelectionDisabled: boolean;
  modelSelectionPending: boolean;
  modelContextTitle?: string;
  modelNotice?: ReactNode;
  actionDisabled: boolean;
  stopAction: "run" | "compact" | null;
  stopDisabled: boolean;
  onDraftChange: (value: ComposerDraft) => void;
  onChooseAttachments: () => void;
  onDropFiles?: (files: File[]) => void;
  onPasteImages?: (files: File[]) => void;
  onCancelAttachments?: () => void;
  onRemoveAttachment: (token: string) => void;
  onSubmit: () => void;
  sendDisabledReason?: MessageId;
  quietDraftChange?: boolean;
  onStop: () => void;
  onSlashCommand: (command: SlashCommandName) => void;
  onRefreshSkillCatalog: () => void;
  onConfirmAccess: () => void;
  onSelectWorkspace: (workspaceId: string) => void;
  onSelectModel: (id: string) => void;
}) {
  const { t } = useI18n();
  const [menuDismissed, setMenuDismissed] = useState(false);
  const [activeCandidateKey, setActiveCandidateKey] = useState<string | null>(
    null,
  );
  const [fileDragActive, setFileDragActive] = useState(false);
  const historyBrowse = useRef<{
    scope: string;
    draft: ComposerDraft;
    initialDraft: ComposerDraft;
    entries: readonly string[] | null;
    index: number;
  } | null>(null);
  const [historyRead, setHistoryRead] = useState<"loading" | "failed" | null>(
    null,
  );
  const historyAvailable = Boolean(inputHistory) && !composeDisabled;
  useEffect(() => {
    const browse = historyBrowse.current;
    if (
      !browse ||
      !historyAvailable ||
      browse.scope !== draftScope ||
      browse.draft !== draft
    ) {
      historyBrowse.current = null;
      setHistoryRead(null);
    }
  }, [draft, draftScope, historyAvailable]);
  useEffect(
    () => () => {
      historyBrowse.current = null;
    },
    [],
  );
  const footerRef = useRef<HTMLElement>(null);
  const firstSkillArgumentRef = useRef<HTMLInputElement>(null);
  const skillRemoveButtonRef = useRef<HTMLButtonElement>(null);
  const sendButtonRef = useRef<HTMLButtonElement>(null);
  const attachmentButtonRef = useRef<HTMLButtonElement>(null);
  const onDropFilesRef = useRef(onDropFiles);
  onDropFilesRef.current = onDropFiles;
  const attachmentRemoveRefs = useRef(new Map<string, HTMLElement>());
  const pendingAttachmentFocusRef = useRef<{
    scope: string;
    removedToken: string;
    adjacentToken: string | null;
  } | null>(null);
  const text = draft.kind === "skill" ? "" : draft.text;
  const draftFocusIdentity =
    draft.kind === "skill"
      ? `skill:${draft.skillId}:${draft.catalogRevision}:${draft.selectionRevision}`
      : draft.kind;
  const previousDraftFocusIdentity = useRef(draftFocusIdentity);
  const slashInput = useMemo(
    () => (draft.kind === "text" ? parseSlashInput(draft.text) : null),
    [draft],
  );
  const attachmentSkillConflict =
    draft.kind === "multimodal" && parseSlashInput(draft.text) !== null;
  const fileDropEnabled =
    attachmentsEnabled &&
    draft.kind !== "skill" &&
    !composeDisabled &&
    !attachmentActionsDisabled &&
    !attachmentBusy;
  const draftProblem =
    draft.kind === "skill" ? skillDraftProblem(draft, skillCatalog) : null;

  const skillDraftCurrent =
    draft.kind !== "skill" || isSkillDraftCurrent(draft, skillCatalog);
  const draftWithinLimits = composerDraftWithinLimits(draft);
  const sendEnabled =
    canSubmit && !attachmentBusy && slashInput === null && draftWithinLimits;
  const hasDraft =
    draft.kind === "skill" ||
    draft.text.length > 0 ||
    (draft.kind === "multimodal" && draft.attachments.length > 0);
  const submitPrimary = () => {
    const input =
      draft.kind === "skill"
        ? firstSkillArgumentRef.current
        : textareaRef.current;
    if (input && !input.disabled) input.focus({ preventScroll: true });
    onSubmit();
  };
  const candidates = useMemo(
    () =>
      slashInput
        ? resolveSlashCandidates({
            input: slashInput,
            commands: slashCommands,
            catalog: skillCatalog,
          })
        : [],
    [skillCatalog, slashCommands, slashInput],
  );
  const activeCandidate =
    candidates.find((candidate) => candidate.key === activeCandidateKey) ??
    candidates.find((candidate) => candidate.enabled) ??
    null;

  const keyboard = useComposerKeyboard({
    draftScope,
    sendEnabled,
    stopAction,
    stopDisabled,
    onStop,
    slash: {
      open: Boolean(slashInput && !menuDismissed),
      canChoose: Boolean(activeCandidate?.enabled),
      move: moveActive,
      choose: () => {
        if (activeCandidate) chooseCandidate(activeCandidate);
      },
      dismiss: () => setMenuDismissed(true),
    },
    onSubmit: submitPrimary,
    onNavigateHistory: navigateInputHistory,
  });
  const composing = keyboard.composing;
  const menuOpen = Boolean(slashInput && !menuDismissed && !composing);
  const showStop = Boolean(stopAction) && !hasDraft && !composing;
  const refreshCatalogRef = useRef(onRefreshSkillCatalog);
  refreshCatalogRef.current = onRefreshSkillCatalog;
  useEffect(() => {
    if (menuOpen) refreshCatalogRef.current();
  }, [menuOpen, draftScope]);

  useEffect(() => {
    if (!fileDropEnabled) setFileDragActive(false);
    let depth = 0;
    const hasFiles = (event: DragEvent) =>
      event.dataTransfer?.types.includes("Files") ?? false;
    const onDragEnter = (event: DragEvent) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      depth += 1;
      if (fileDropEnabled) setFileDragActive(true);
    };
    const onDragOver = (event: DragEvent) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
    };
    const clear = (event: DragEvent) => {
      if (!hasFiles(event) && event.type !== "dragend") return;
      event.preventDefault();
      depth = 0;
      setFileDragActive(false);
    };
    const onDragLeave = (event: DragEvent) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      depth = Math.max(0, depth - 1);
      if (depth === 0) setFileDragActive(false);
    };
    const onDrop = (event: DragEvent) => {
      clear(event);
      if (fileDropEnabled && event.dataTransfer?.files.length)
        onDropFilesRef.current?.(Array.from(event.dataTransfer.files));
    };
    document.addEventListener("dragenter", onDragEnter);
    document.addEventListener("dragover", onDragOver);
    document.addEventListener("dragleave", onDragLeave);
    document.addEventListener("drop", onDrop);
    document.addEventListener("dragend", clear);
    return () => {
      document.removeEventListener("dragenter", onDragEnter);
      document.removeEventListener("dragover", onDragOver);
      document.removeEventListener("dragleave", onDragLeave);
      document.removeEventListener("drop", onDrop);
      document.removeEventListener("dragend", clear);
    };
  }, [fileDropEnabled]);

  const chooseCandidate = useCallback(
    (candidate: SlashCandidate) => {
      if (!candidate.enabled) return;
      if (candidate.kind === "skill") {
        onDraftChange(skillDraftFromCandidate(candidate));
      } else {
        onDraftChange(emptyComposerDraft());
        onSlashCommand(candidate.name);
      }
      setMenuDismissed(false);
      setActiveCandidateKey(null);
    },
    [onDraftChange, onSlashCommand],
  );

  useEffect(() => {
    if (previousDraftFocusIdentity.current === draftFocusIdentity) return;
    previousDraftFocusIdentity.current = draftFocusIdentity;
    if (quietDraftChange || pendingAttachmentFocusRef.current) return;
    const frame = window.requestAnimationFrame(() => {
      const firstArgument = firstSkillArgumentRef.current;
      const sendButton = sendButtonRef.current;
      const target =
        draft.kind === "skill"
          ? firstArgument && !firstArgument.disabled
            ? firstArgument
            : sendButton && !sendButton.disabled
              ? sendButton
              : skillRemoveButtonRef.current
          : textareaRef.current;
      if (
        document.activeElement === document.body ||
        footerRef.current?.contains(document.activeElement)
      )
        target?.focus({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [draft.kind, draftFocusIdentity, textareaRef, quietDraftChange]);

  useEffect(() => {
    const pending = pendingAttachmentFocusRef.current;
    if (!pending) return;
    if (pending.scope !== draftScope) {
      pendingAttachmentFocusRef.current = null;
      return;
    }
    if (attachmentBusy) return;
    if (
      draft.kind === "multimodal" &&
      draft.attachments.some(
        (attachment) => attachment.token === pending.removedToken,
      )
    )
      return;
    const frame = window.requestAnimationFrame(() => {
      if (pendingAttachmentFocusRef.current !== pending) return;
      const target = pending.adjacentToken
        ? attachmentRemoveRefs.current.get(pending.adjacentToken)
        : attachmentButtonRef.current;
      if (target && !target.hasAttribute("disabled")) target.focus();
      pendingAttachmentFocusRef.current = null;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [draft, draftScope, attachmentBusy]);

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea || typeof window === "undefined") return;
    resizeComposerTextarea(textarea);
  }, [text, textareaRef]);

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea || typeof window === "undefined") return;
    const resize = () => resizeComposerTextarea(textarea);
    const observer =
      typeof ResizeObserver === "undefined" ? null : new ResizeObserver(resize);
    observer?.observe(textarea);
    window.addEventListener("resize", resize);
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", resize);
    };
  }, [textareaRef]);

  function moveActive(direction: 1 | -1) {
    const enabled = candidates.filter((candidate) => candidate.enabled);
    if (enabled.length === 0) return;
    const current = enabled.findIndex(
      (candidate) => candidate.key === activeCandidate?.key,
    );
    const next =
      current < 0 ? 0 : (current + direction + enabled.length) % enabled.length;
    setActiveCandidateKey(enabled[next]?.key ?? null);
  }

  function navigateInputHistory(direction: -1 | 1): boolean {
    if (!inputHistory || composeDisabled) return false;
    // Read the owner's ref: an external commit may precede its React render.
    const current = inputHistory.currentDraft();
    let browse = historyBrowse.current;
    if (browse && (browse.scope !== draftScope || browse.draft !== current)) {
      historyBrowse.current = null;
      setHistoryRead(null);
      return false;
    }
    if (!browse) {
      if (!current || direction !== -1 || !canEnterInputHistory(current))
        return false;
      // An uncached draft is decoded afresh on each owner read. Pin this empty
      // object through the normal write path before awaiting history.
      if (!inputHistory.commitDraft(current)) return false;
      const request = {
        scope: draftScope,
        draft: current,
        initialDraft: current,
        entries: null as readonly string[] | null,
        index: 0,
      };
      historyBrowse.current = request;
      setHistoryRead("loading");
      void inputHistory.load().then(
        (entries) => {
          if (
            historyBrowse.current !== request ||
            inputHistory.currentDraft() !== request.draft
          )
            return;
          setHistoryRead(null);
          if (!entries.length) {
            historyBrowse.current = null;
            return;
          }
          request.entries = [...entries];
          request.index = entries.length - 1;
          const next: ComposerDraft = {
            kind: "text",
            text: entries[request.index]!,
          };
          request.draft = next;
          if (!inputHistory.commitDraft(next)) historyBrowse.current = null;
        },
        () => {
          if (historyBrowse.current !== request) return;
          historyBrowse.current = null;
          setHistoryRead(
            inputHistory.currentDraft() === request.draft ? "failed" : null,
          );
        },
      );
      return true;
    }
    if (!browse.entries) return true;
    const index = Math.max(0, browse.index + direction);
    if (index === browse.index) return true;
    const finished = index === browse.entries.length;
    const next: ComposerDraft = finished
      ? browse.initialDraft
      : { kind: "text", text: browse.entries[index]! };
    browse.index = index;
    browse.draft = next;
    if (!inputHistory.commitDraft(next) || finished)
      historyBrowse.current = null;
    return true;
  }

  function updateText(value: string) {
    pendingAttachmentFocusRef.current = null;
    if (draft.kind === "multimodal") {
      onDraftChange({ ...draft, text: value });
      return;
    }
    onDraftChange({
      kind: "text",
      text: value,
      ...(draft.kind === "text" && draft.attachmentsReloadRequired
        ? { attachmentsReloadRequired: true as const }
        : {}),
    });
  }

  function pasteImages(event: ClipboardEvent<HTMLTextAreaElement>) {
    if (composeDisabled || !onPasteImages) return;
    const files: File[] = [];
    for (const item of Array.from(event.clipboardData.items)) {
      if (item.kind !== "file" || !item.type.startsWith("image/")) continue;
      const file = item.getAsFile();
      if (!file) continue;
      files.push(
        file.name
          ? file
          : new File([file], "pasted-image", {
              type: file.type,
              lastModified: file.lastModified,
            }),
      );
    }
    if (!files.length) return;
    event.preventDefault();
    onPasteImages(files);
  }

  function removeAttachment(attachment: ComposerAttachment, index: number) {
    const adjacent =
      draft.kind === "multimodal"
        ? (draft.attachments[index + 1] ?? draft.attachments[index - 1])
        : undefined;
    pendingAttachmentFocusRef.current = {
      scope: draftScope,
      removedToken: attachment.token,
      adjacentToken: adjacent?.token ?? null,
    };
    onRemoveAttachment(attachment.token);
  }

  function updateSkillArgument(
    skill: ComposerSkillDraft,
    index: number,
    value: string,
  ) {
    const values = [...skill.argumentValues];
    values[index] = value.slice(0, maxComposerCharacters);
    onDraftChange({ ...skill, argumentValues: values });
  }

  function appendSkillArgument(skill: ComposerSkillDraft) {
    const visible = skillDraftVisibleArgumentCount(skill);
    if (visible >= skill.maxValues) return;
    const values = Array.from(
      { length: visible + 1 },
      (_, index) => skill.argumentValues[index] ?? "",
    );
    onDraftChange({ ...skill, argumentValues: values });
  }

  function removeLastSkillArgument(skill: ComposerSkillDraft) {
    if (skill.argumentValues.length <= skill.argumentNames.length) return;
    onDraftChange({
      ...skill,
      argumentValues: skill.argumentValues.slice(0, -1),
    });
  }

  const workspaceContext = (
    <WorkspaceContextSelector
      accessRequired={accessRequired}
      label={workspaceLabel}
      title={workspaceTitle}
      diagnostic={workspaceDiagnostic}
      options={workspaceOptions}
      selectedId={selectedWorkspaceOptionId}
      disabled={actionDisabled || workspaceSelectionPending}
      onConfirmAccess={onConfirmAccess}
      onSelect={onSelectWorkspace}
    />
  );

  return (
    <footer
      ref={footerRef}
      className="composer-bar"
      onCompositionStartCapture={keyboard.onCompositionStartCapture}
      onCompositionEndCapture={keyboard.onCompositionEndCapture}
      onFocusCapture={keyboard.onFocusCapture}
      onBlurCapture={keyboard.onBlurCapture}
      onKeyDownCapture={keyboard.onKeyDownCapture}
      onKeyDown={keyboard.onKeyDown}
      onPointerDownCapture={keyboard.onPointerDownCapture}
      onChangeCapture={keyboard.onChangeCapture}
    >
      <div className="composer-shell" data-file-drag-active={fileDragActive}>
        {fileDragActive && (
          <div className="composer-file-drop" aria-hidden="true">
            <Icon name="paperclip" />
            <span>{t("attachment.drop")}</span>
          </div>
        )}
        {menuOpen && slashInput && (
          <SlashMenu
            input={slashInput}
            commands={slashCommands}
            catalog={skillCatalog}
            skillsOnly={slashInput.explicitSkill}
            activeKey={activeCandidate?.key ?? null}
            onActiveKey={setActiveCandidateKey}
            onChoose={chooseCandidate}
            onRefresh={onRefreshSkillCatalog}
          />
        )}
        <Composer
          state={
            unavailable || archived || closing
              ? "unavailable"
              : runInFlight
                ? "running"
                : "normal"
          }
        >
          {draft.kind !== "skill" ? (
            <>
              {draft.kind === "multimodal" && (
                <div
                  className="composer-attachments"
                  role="list"
                  aria-label={t("attachment.selected")}
                >
                  {draft.attachments.map((attachment, index) => (
                    <div
                      className="composer-attachment"
                      role="listitem"
                      key={attachment.token}
                    >
                      <span
                        className="composer-attachment-kind"
                        aria-hidden="true"
                      >
                        {attachment.kind === "image" ? (
                          attachment.format.toUpperCase()
                        ) : (
                          <Icon name="skill-file" />
                        )}
                      </span>
                      <span className="composer-attachment-copy">
                        <strong dir="auto" title={attachment.displayName}>
                          {attachment.displayName}
                        </strong>
                        <small>
                          {attachmentTypeLabel(attachment, t)} ·{" "}
                          {formatAttachmentSize(attachment.sizeBytes)}
                        </small>
                      </span>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        ref={(node) => {
                          if (node)
                            attachmentRemoveRefs.current.set(
                              attachment.token,
                              node,
                            );
                          else
                            attachmentRemoveRefs.current.delete(
                              attachment.token,
                            );
                        }}
                        className="composer-attachment-remove"
                        aria-label={t("attachment.remove", {
                          name: attachment.displayName,
                        })}
                        disabled={
                          composeDisabled ||
                          attachmentActionsDisabled ||
                          attachmentBusy
                        }
                        onClick={() => removeAttachment(attachment, index)}
                      >
                        <Icon name="close" />
                      </Button>
                    </div>
                  ))}
                </div>
              )}
              {draft.kind === "text" && draft.attachmentsReloadRequired && (
                <p className="composer-attachment-notice" role="status">
                  {t("attachment.reload_required")}
                </p>
              )}
              {attachmentSkillConflict && (
                <p className="composer-attachment-notice" role="status">
                  {t("attachment.skill_conflict")}
                </p>
              )}
              {attachmentModelWarning && (
                <p className="composer-attachment-capability" role="status">
                  {t(`attachment.model_warning.${attachmentModelWarning}`)}
                </p>
              )}
              <Textarea
                ref={textareaRef}
                value={draft.text}
                disabled={composeDisabled}
                role="combobox"
                aria-autocomplete="list"
                aria-expanded={menuOpen}
                aria-controls={menuOpen ? "composer-slash-menu" : undefined}
                aria-activedescendant={
                  menuOpen && activeCandidate
                    ? `slash-option-${activeCandidate.key.replaceAll(":", "-")}`
                    : undefined
                }
                placeholder={
                  closing
                    ? t("run.placeholder_closing")
                    : unavailable
                      ? t(
                          unavailableReason === "session_recovery_required" ||
                            unavailableReason ===
                              "session_recovery_in_progress" ||
                            unavailableReason === "session_recovery_failed"
                            ? "run.placeholder"
                            : unavailableReason === "execution_rebind_required"
                              ? "run.placeholder_execution_rebind_required"
                              : unavailableReason === "history_read_only"
                                ? "run.placeholder_history_read_only"
                                : "run.placeholder_unavailable",
                        )
                      : archived
                        ? t("run.placeholder_archived")
                        : t("run.placeholder")
                }
                onCompositionEnd={(event) => {
                  updateText(event.currentTarget.value);
                }}
                onChange={(event) => {
                  setMenuDismissed(false);
                  updateText(event.target.value);
                }}
                onKeyDown={keyboard.onTextKeyDown}
                onPaste={pasteImages}
              />
              {historyRead && (
                <p className="composer-attachment-notice" role="status">
                  {t(`run.input_history_${historyRead}`)}
                </p>
              )}
              {!draftWithinLimits && (
                <p className="composer-attachment-error" role="status">
                  {t("run.text_input_too_large")}
                </p>
              )}
            </>
          ) : (
            <div className="skill-draft">
              <div className="skill-draft-identity">
                <span className="skill-draft-mark" aria-hidden="true">
                  /
                </span>
                <span>
                  <strong>{draft.displayName || draft.invocationName}</strong>
                  <small>/skill:{draft.invocationName}</small>
                </span>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  ref={skillRemoveButtonRef}
                  className="skill-draft-remove"
                  aria-label={t("slash.remove_skill")}
                  onClick={() => onDraftChange(emptyComposerDraft())}
                >
                  <Icon name="close" />
                </Button>
              </div>
              {skillDraftVisibleArgumentCount(draft) > 0 && (
                <div
                  className="skill-arguments"
                  role="group"
                  aria-label={t("slash.arguments")}
                >
                  {Array.from({
                    length: skillDraftVisibleArgumentCount(draft),
                  }).map((_, index) => (
                    <label
                      key={`${draft.argumentNames[index] ?? "arg"}:${index}`}
                    >
                      <span>
                        {draft.argumentNames[index] ||
                          t("slash.argument", { index: String(index + 1) })}
                      </span>
                      <Input
                        ref={index === 0 ? firstSkillArgumentRef : undefined}
                        value={draft.argumentValues[index] ?? ""}
                        maxLength={maxComposerCharacters}
                        disabled={composeDisabled}
                        onChange={(event) =>
                          updateSkillArgument(draft, index, event.target.value)
                        }
                        onKeyDown={keyboard.onSkillKeyDown}
                      />
                    </label>
                  ))}
                  <div className="skill-argument-actions">
                    {skillDraftVisibleArgumentCount(draft) <
                      draft.maxValues && (
                      <Button
                        type="button"
                        variant="secondary"
                        size="sm"
                        className="slash-refresh"
                        disabled={composeDisabled}
                        onClick={() => appendSkillArgument(draft)}
                      >
                        {t("slash.add_argument")}
                      </Button>
                    )}
                    {draft.argumentValues.length >
                      draft.argumentNames.length && (
                      <Button
                        type="button"
                        variant="secondary"
                        size="sm"
                        className="slash-refresh"
                        disabled={composeDisabled}
                        onClick={() => removeLastSkillArgument(draft)}
                      >
                        {t("slash.remove_argument")}
                      </Button>
                    )}
                  </div>
                </div>
              )}
              {!skillDraftCurrent && (
                <div className="skill-draft-warning" role="status">
                  <span>
                    {t(
                      draftProblem === "arguments"
                        ? "slash.skill_arguments_changed"
                        : draftProblem === "disabled"
                          ? "slash.skill_disabled"
                          : draftProblem === "catalog"
                            ? "slash.skills_unavailable"
                            : "slash.skill_stale",
                    )}
                  </span>
                  <Button
                    type="button"
                    variant="secondary"
                    size="sm"
                    className="slash-refresh"
                    onClick={() =>
                      draftProblem === "arguments"
                        ? onDraftChange(reviewSkillDraft(draft, skillCatalog))
                        : onRefreshSkillCatalog()
                    }
                  >
                    {t(
                      draftProblem === "arguments"
                        ? "slash.review_arguments"
                        : "slash.refresh",
                    )}
                  </Button>
                </div>
              )}
              {!draftWithinLimits && (
                <div className="skill-draft-warning" role="status">
                  <span>{t("slash.skill_input_too_large")}</span>
                </div>
              )}
            </div>
          )}
          <div
            className="ai-composer-toolbar"
            role="group"
            aria-label={t("run.context")}
          >
            <div className="composer-context-actions">
              {attachmentsEnabled && draft.kind !== "skill" && (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  ref={attachmentButtonRef}
                  className="composer-attachment-add"
                  data-busy={attachmentBusy || undefined}
                  aria-busy={attachmentBusy || undefined}
                  aria-label={t(
                    attachmentRemoving
                      ? "attachment.removing"
                      : attachmentCancelling
                        ? "attachment.cancelling"
                        : attachmentBusy && onCancelAttachments
                          ? "attachment.cancel"
                          : "attachment.add",
                  )}
                  title={t(
                    attachmentRemoving
                      ? "attachment.removing"
                      : attachmentCancelling
                        ? "attachment.cancelling"
                        : attachmentBusy && onCancelAttachments
                          ? "attachment.cancel"
                          : "attachment.add",
                  )}
                  disabled={
                    composeDisabled ||
                    attachmentActionsDisabled ||
                    attachmentCancelling ||
                    (attachmentBusy && !onCancelAttachments)
                  }
                  onClick={
                    attachmentBusy ? onCancelAttachments : onChooseAttachments
                  }
                >
                  <Icon
                    name={
                      attachmentBusy
                        ? onCancelAttachments
                          ? "close"
                          : "loading"
                        : "plus"
                    }
                  />
                </Button>
              )}
              {approvalModeControl}
              {workspaceEditable && workspaceContext}
            </div>
            <div className="composer-model-actions">
              {modelLabel && (
                <span className="composer-model-context">
                  <span className="sr-only">{t("account.model")}</span>
                  <ModelSelector
                    triggerRef={modelTriggerRef}
                    label={modelLabel}
                    options={modelOptions}
                    selectedId={selectedModelId}
                    editable={modelEditable}
                    disabled={modelSelectionDisabled}
                    pending={modelSelectionPending}
                    contextTitle={modelContextTitle}
                    onSelect={onSelectModel}
                  />
                </span>
              )}
              {showStop ? (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="composer-stop"
                  aria-label={t(
                    keyboard.stopConfirming
                      ? "task.stop_confirm"
                      : stopAction === "compact"
                        ? "compact.stop"
                        : "task.stop",
                  )}
                  title={t(
                    keyboard.stopConfirming
                      ? "task.stop_confirm"
                      : stopAction === "compact"
                        ? "compact.stop"
                        : "task.stop",
                  )}
                  disabled={stopDisabled}
                  onClick={onStop}
                >
                  {keyboard.stopConfirming ? (
                    <span className="composer-stop-confirm" aria-hidden="true">
                      Esc
                    </span>
                  ) : (
                    <Icon name="stop" />
                  )}
                </Button>
              ) : (
                <Button
                  type="button"
                  variant="primary"
                  size="icon"
                  ref={sendButtonRef}
                  className="composer-send"
                  aria-label={t("run.submit")}
                  title={t(sendDisabledReason ?? "run.submit")}
                  disabled={!sendEnabled}
                  onClick={submitPrimary}
                >
                  <Icon name="send" />
                </Button>
              )}
            </div>
          </div>
        </Composer>
        {attachmentError && (
          <p className="composer-attachment-error" role="alert">
            {t(attachmentErrorMessage(attachmentError), {
              limit: (
                Number(attachmentMaxFileBytes) / 1_000_000
              ).toLocaleString(),
            })}
          </p>
        )}
      </div>
      {modelNotice}
      {sendDisabledReason && (
        <p className="composer-draft-note" role="status">
          {t(sendDisabledReason)}
        </p>
      )}
    </footer>
  );
}
