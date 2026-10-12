import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
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
import { ModelSelector } from "./ModelSelector.tsx";
import { SlashMenu } from "./SlashMenu.tsx";
import {
  composerDraftWithinLimits,
  emptyComposerDraft,
  isSkillDraftCurrent,
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
    cleanup_failed: "attachment.error.cleanup_failed",
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
  attachmentsEnabled,
  attachmentMaxFileBytes,
  attachmentBusy,
  attachmentCancelling = false,
  attachmentError,
  attachmentModelWarning,
  skillCatalog,
  slashCommands,
  composeDisabled,
  canSubmit,
  runInFlight,
  accessRequired,
  workspaceMissing,
  workspaceLabel,
  workspaceTitle,
  workspaceOptions,
  selectedWorkspaceOptionId,
  workspaceEditable,
  modelLabel,
  modelOptions,
  selectedModelId,
  modelEditable,
  modelSelectionDisabled,
  modelSelectionPending,
  modelContextTitle,
  defaultSelectionMissing,
  defaultRecoveryDisabled,
  actionDisabled,
  stopAction,
  stopDisabled,
  onDraftChange,
  onChooseAttachments,
  onDropFiles,
  onCancelAttachments,
  onRemoveAttachment,
  onSubmit,
  onStop,
  onSlashCommand,
  onRefreshSkillCatalog,
  onConfirmAccess,
  onSelectWorkspace,
  onSelectModel,
  onOpenModels,
}: {
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  approvalModeControl?: ReactNode;
  archived: boolean;
  closing: boolean;
  unavailable: boolean;
  unavailableReason: TaskView["continuationUnavailableReason"];
  draft: ComposerDraft;
  attachmentsEnabled: boolean;
  attachmentMaxFileBytes: string;
  attachmentBusy: boolean;
  attachmentCancelling?: boolean;
  attachmentError: string | null;
  attachmentModelWarning: "image" | null;
  skillCatalog: SkillCatalogView;
  slashCommands: readonly SlashCommandState[];
  composeDisabled: boolean;
  canSubmit: boolean;
  runInFlight: boolean;
  accessRequired: boolean;
  workspaceMissing: boolean;
  workspaceLabel: string;
  workspaceTitle: string;
  workspaceOptions: {
    id: string;
    label: string;
    description?: string;
    authorization: "available" | "removing" | "reauthorization_required";
    disabled?: boolean;
  }[];
  selectedWorkspaceOptionId: string;
  workspaceEditable: boolean;
  modelLabel: string | null;
  modelOptions: {
    selectionId: string;
    displayName: string;
    triggerLabel?: string;
  }[];
  selectedModelId: string;
  modelEditable: boolean;
  modelSelectionDisabled: boolean;
  modelSelectionPending: boolean;
  modelContextTitle: string;
  defaultSelectionMissing: boolean;
  defaultRecoveryDisabled: boolean;
  actionDisabled: boolean;
  stopAction: "run" | "compact" | null;
  stopDisabled: boolean;
  onDraftChange: (value: ComposerDraft) => void;
  onChooseAttachments: () => void;
  onDropFiles?: (files: File[]) => void;
  onCancelAttachments?: () => void;
  onRemoveAttachment: (token: string) => void;
  onSubmit: () => void;
  onStop: () => void;
  onSlashCommand: (command: SlashCommandName) => void;
  onRefreshSkillCatalog: () => void;
  onConfirmAccess: () => void;
  onSelectWorkspace: (workspaceId: string) => void;
  onSelectModel: (id: string) => void;
  onOpenModels: () => void;
}) {
  const { t } = useI18n();
  const [menuDismissed, setMenuDismissed] = useState(false);
  const [activeCandidateKey, setActiveCandidateKey] = useState<string | null>(
    null,
  );
  const [composing, setComposing] = useState(false);
  const [fileDragActive, setFileDragActive] = useState(false);
  const firstSkillArgumentRef = useRef<HTMLInputElement>(null);
  const skillRemoveButtonRef = useRef<HTMLButtonElement>(null);
  const sendButtonRef = useRef<HTMLButtonElement>(null);
  const stopButtonRef = useRef<HTMLButtonElement>(null);
  const attachmentButtonRef = useRef<HTMLButtonElement>(null);
  const onDropFilesRef = useRef(onDropFiles);
  onDropFilesRef.current = onDropFiles;
  const attachmentRemoveRefs = useRef(new Map<string, HTMLElement>());
  const pendingAttachmentFocusRef = useRef<{
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
    !attachmentBusy;
  const menuOpen = Boolean(slashInput && !menuDismissed && !composing);
  const skillDraftCurrent =
    draft.kind !== "skill" || isSkillDraftCurrent(draft, skillCatalog);
  const draftWithinLimits = composerDraftWithinLimits(draft);
  const sendEnabled = canSubmit && slashInput === null && draftWithinLimits;
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
    if (pendingAttachmentFocusRef.current) return;
    const frame = window.requestAnimationFrame(() => {
      const firstArgument = firstSkillArgumentRef.current;
      const sendButton = sendButtonRef.current;
      const target =
        draft.kind === "skill"
          ? firstArgument && !firstArgument.disabled
            ? firstArgument
            : stopAction &&
                stopButtonRef.current &&
                !stopButtonRef.current.disabled
              ? stopButtonRef.current
              : sendButton && !sendButton.disabled
                ? sendButton
                : skillRemoveButtonRef.current
          : textareaRef.current;
      target?.focus();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [draft.kind, draftFocusIdentity, textareaRef]);

  useEffect(() => {
    const pending = pendingAttachmentFocusRef.current;
    if (!pending) return;
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
      target?.focus();
      pendingAttachmentFocusRef.current = null;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [draft]);

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

  function handleTextKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.nativeEvent.isComposing) return;
    if (menuOpen) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        moveActive(event.key === "ArrowDown" ? 1 : -1);
        return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        setMenuDismissed(true);
        return;
      }
      if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault();
        if (activeCandidate) chooseCandidate(activeCandidate);
        return;
      }
    }
    if (event.key === "Enter" && !event.shiftKey && sendEnabled) {
      event.preventDefault();
      onSubmit();
    }
  }

  function updateText(value: string) {
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

  function removeAttachment(attachment: ComposerAttachment, index: number) {
    const adjacent =
      draft.kind === "multimodal"
        ? (draft.attachments[index + 1] ?? draft.attachments[index - 1])
        : undefined;
    pendingAttachmentFocusRef.current = {
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

  return (
    <footer className="composer-bar">
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
                        disabled={composeDisabled || attachmentBusy}
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
                              : "run.placeholder_unavailable",
                        )
                      : archived
                        ? t("run.placeholder_archived")
                        : t("run.placeholder")
                }
                onCompositionStart={() => setComposing(true)}
                onCompositionEnd={(event) => {
                  setComposing(false);
                  updateText(event.currentTarget.value);
                }}
                onChange={(event) => {
                  setMenuDismissed(false);
                  updateText(event.target.value);
                }}
                onKeyDown={handleTextKeyDown}
              />
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
                        onKeyDown={(event) => {
                          if (
                            event.key === "Enter" &&
                            !event.nativeEvent.isComposing &&
                            sendEnabled
                          ) {
                            event.preventDefault();
                            onSubmit();
                          }
                        }}
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
                  <span>{t("slash.skill_stale")}</span>
                  <Button
                    type="button"
                    variant="secondary"
                    size="sm"
                    className="slash-refresh"
                    onClick={onRefreshSkillCatalog}
                  >
                    {t("slash.refresh")}
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
                    attachmentCancelling
                      ? "attachment.cancelling"
                      : attachmentBusy && onCancelAttachments
                        ? "attachment.cancel"
                        : "attachment.add",
                  )}
                  title={t(
                    attachmentCancelling
                      ? "attachment.cancelling"
                      : attachmentBusy && onCancelAttachments
                        ? "attachment.cancel"
                        : "attachment.add",
                  )}
                  disabled={
                    composeDisabled ||
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
              {modelLabel && (
                <span className="composer-model-context">
                  <span className="sr-only">{t("account.model")}</span>
                  <ModelSelector
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
            </div>
            {stopAction ? (
              <Button
                type="button"
                variant="danger"
                size="icon"
                ref={stopButtonRef}
                className="composer-stop"
                aria-label={t(
                  stopAction === "compact" ? "compact.stop" : "task.stop",
                )}
                title={t(
                  stopAction === "compact" ? "compact.stop" : "task.stop",
                )}
                disabled={stopDisabled}
                onClick={onStop}
              >
                <Icon name="stop" />
              </Button>
            ) : (
              <div className="composer-send-group">
                {defaultSelectionMissing && (
                  <span className="composer-default-recovery" role="status">
                    <span>{t("settings.default_selection_missing")}</span>
                    <Button
                      type="button"
                      variant="secondary"
                      size="sm"
                      disabled={defaultRecoveryDisabled}
                      onClick={onOpenModels}
                    >
                      {t("settings.open_models")}
                    </Button>
                  </span>
                )}
                <Button
                  type="button"
                  variant="primary"
                  size="icon"
                  ref={sendButtonRef}
                  className="composer-send"
                  aria-label={t("run.submit")}
                  title={t("run.submit")}
                  disabled={!sendEnabled}
                  onClick={onSubmit}
                >
                  <Icon name="send" />
                </Button>
              </div>
            )}
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
        <WorkspaceContextSelector
          accessRequired={accessRequired}
          missing={workspaceMissing}
          label={workspaceLabel}
          title={workspaceTitle}
          options={workspaceOptions}
          selectedId={selectedWorkspaceOptionId}
          editable={workspaceEditable}
          disabled={actionDisabled}
          onConfirmAccess={onConfirmAccess}
          onSelect={onSelectWorkspace}
        />
      </div>
      {runInFlight && (
        <p className="composer-draft-note">{t("run.draft_only")}</p>
      )}
    </footer>
  );
}
