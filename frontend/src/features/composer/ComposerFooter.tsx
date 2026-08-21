import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type RefObject,
} from "react";

import type { SkillCatalogView, TaskView } from "../../bridge/contracts.ts";
import { Composer } from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Input } from "../../components/ui/input.tsx";
import { Textarea } from "../../components/ui/textarea.tsx";
import { useI18n } from "../../i18n/context.ts";
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

export function ComposerFooter({
  textareaRef,
  archived,
  closing,
  unavailable,
  unavailableReason,
  recoveryAvailable,
  recoveryInProgress,
  recoveryDisabled,
  draft,
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
  actionDisabled,
  stopAction,
  stopDisabled,
  onDraftChange,
  onSubmit,
  onStop,
  onRestore,
  onSlashCommand,
  onRefreshSkillCatalog,
  onConfirmAccess,
  onSelectWorkspace,
  onSelectModel,
}: {
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  archived: boolean;
  closing: boolean;
  unavailable: boolean;
  unavailableReason: TaskView["continuationUnavailableReason"];
  recoveryAvailable: boolean;
  recoveryInProgress: boolean;
  recoveryDisabled: boolean;
  draft: ComposerDraft;
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
  actionDisabled: boolean;
  stopAction: "run" | "compact" | null;
  stopDisabled: boolean;
  onDraftChange: (value: ComposerDraft) => void;
  onSubmit: () => void;
  onStop: () => void;
  onRestore: () => void;
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
  const [composing, setComposing] = useState(false);
  const firstSkillArgumentRef = useRef<HTMLInputElement>(null);
  const skillRemoveButtonRef = useRef<HTMLButtonElement>(null);
  const recoveryFailed = unavailableReason === "session_recovery_failed";
  const recoveryVisible = recoveryAvailable || recoveryInProgress;
  const sendButtonRef = useRef<HTMLButtonElement>(null);
  const stopButtonRef = useRef<HTMLButtonElement>(null);
  const text = draft.kind === "text" ? draft.text : "";
  const draftFocusIdentity =
    draft.kind === "skill"
      ? `skill:${draft.skillId}:${draft.catalogRevision}:${draft.selectionRevision}`
      : "text";
  const previousDraftFocusIdentity = useRef(draftFocusIdentity);
  const slashInput = useMemo(
    () => (draft.kind === "text" ? parseSlashInput(draft.text) : null),
    [draft],
  );
  const menuOpen = Boolean(slashInput && !menuDismissed && !composing);
  const sendEnabled = canSubmit && slashInput === null;
  const skillDraftCurrent =
    draft.kind !== "skill" || isSkillDraftCurrent(draft, skillCatalog);
  const draftWithinLimits = composerDraftWithinLimits(draft);
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
      <div className="composer-shell">
        {recoveryVisible && (
          <section
            className="conversation-recovery"
            data-state={
              recoveryInProgress
                ? "in-progress"
                : recoveryFailed
                  ? "failed"
                  : "required"
            }
            role="status"
            aria-live="polite"
          >
            <div>
              <strong>
                {t(
                  recoveryInProgress
                    ? "recovery.title_in_progress"
                    : recoveryFailed
                      ? "recovery.title_failed"
                      : "recovery.title_required",
                )}
              </strong>
              <p>
                {t(
                  recoveryInProgress
                    ? "recovery.help_in_progress"
                    : recoveryFailed
                      ? "recovery.help_failed"
                      : "recovery.help_required",
                )}
              </p>
            </div>
            <Button
              type="button"
              variant="primary"
              size="md"
              className="recovery-action"
              disabled={recoveryDisabled || recoveryInProgress}
              onClick={onRestore}
            >
              {t(
                recoveryInProgress
                  ? "recovery.progress"
                  : recoveryFailed
                    ? "recovery.retry"
                    : "recovery.action",
              )}
            </Button>
          </section>
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
          {draft.kind === "text" ? (
            <Textarea
              ref={textareaRef}
              value={draft.text}
              maxLength={maxComposerCharacters}
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
                          ? "run.placeholder_recovery_required"
                          : "run.placeholder_unavailable",
                      )
                    : archived
                      ? t("run.placeholder_archived")
                      : t("run.placeholder")
              }
              onCompositionStart={() => setComposing(true)}
              onCompositionEnd={(event) => {
                setComposing(false);
                onDraftChange({
                  kind: "text",
                  text: event.currentTarget.value,
                });
              }}
              onChange={(event) => {
                setMenuDismissed(false);
                onDraftChange({ kind: "text", text: event.target.value });
              }}
              onKeyDown={handleTextKeyDown}
            />
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
            )}
          </div>
        </Composer>
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
