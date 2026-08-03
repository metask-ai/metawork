import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type RefObject,
} from "react";

import type { SkillCatalogView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
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
  closed,
  unavailable,
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
  selectedWorkspaceId,
  workspaceEditable,
  modelLabel,
  modelOptions,
  selectedModelId,
  modelEditable,
  modelSelectionDisabled,
  modelSelectionPending,
  modelContextTitle,
  actionDisabled,
  onDraftChange,
  onSubmit,
  onSlashCommand,
  onRefreshSkillCatalog,
  onConfirmAccess,
  onSelectWorkspace,
  onSelectModel,
}: {
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  archived: boolean;
  closing: boolean;
  closed: boolean;
  unavailable: boolean;
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
  }[];
  selectedWorkspaceId: string;
  workspaceEditable: boolean;
  modelLabel: string | null;
  modelOptions: { selectionId: string; displayName: string }[];
  selectedModelId: string;
  modelEditable: boolean;
  modelSelectionDisabled: boolean;
  modelSelectionPending: boolean;
  modelContextTitle: string;
  actionDisabled: boolean;
  onDraftChange: (value: ComposerDraft) => void;
  onSubmit: () => void;
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
  const sendButtonRef = useRef<HTMLButtonElement>(null);
  const text = draft.kind === "text" ? draft.text : "";
  const draftFocusIdentity =
    draft.kind === "skill"
      ? `skill:${draft.skillId}:${draft.catalogRevision}`
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
        <div className="composer">
          {draft.kind === "text" ? (
            <textarea
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
                closed
                  ? t("run.placeholder_closed")
                  : closing
                    ? t("run.placeholder_closing")
                    : unavailable
                      ? t("run.placeholder_unavailable")
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
                <button
                  ref={skillRemoveButtonRef}
                  type="button"
                  className="skill-draft-remove focus-ring"
                  aria-label={t("slash.remove_skill")}
                  onClick={() => onDraftChange(emptyComposerDraft())}
                >
                  <Icon name="close" />
                </button>
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
                      <input
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
                      <button
                        type="button"
                        className="slash-refresh focus-ring"
                        disabled={composeDisabled}
                        onClick={() => appendSkillArgument(draft)}
                      >
                        {t("slash.add_argument")}
                      </button>
                    )}
                    {draft.argumentValues.length >
                      draft.argumentNames.length && (
                      <button
                        type="button"
                        className="slash-refresh focus-ring"
                        disabled={composeDisabled}
                        onClick={() => removeLastSkillArgument(draft)}
                      >
                        {t("slash.remove_argument")}
                      </button>
                    )}
                  </div>
                </div>
              )}
              {!skillDraftCurrent && (
                <div className="skill-draft-warning" role="status">
                  <span>{t("slash.skill_stale")}</span>
                  <button
                    type="button"
                    className="slash-refresh focus-ring"
                    onClick={onRefreshSkillCatalog}
                  >
                    {t("slash.refresh")}
                  </button>
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
            className="composer-toolbar"
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
            <button
              ref={sendButtonRef}
              className="composer-send focus-ring"
              aria-label={t("run.submit")}
              title={t("run.submit")}
              disabled={!sendEnabled}
              onClick={onSubmit}
            >
              <Icon name="send" />
            </button>
          </div>
        </div>
        <WorkspaceContextSelector
          accessRequired={accessRequired}
          missing={workspaceMissing}
          label={workspaceLabel}
          title={workspaceTitle}
          options={workspaceOptions}
          selectedId={selectedWorkspaceId}
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
