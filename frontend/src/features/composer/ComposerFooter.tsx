import { useEffect, type RefObject } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { maxComposerCharacters } from "./drafts.ts";
import { ModelSelector } from "./ModelSelector.tsx";
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
  prompt,
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
  onPromptChange,
  onSubmit,
  onConfirmAccess,
  onSelectWorkspace,
  onSelectModel,
}: {
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  archived: boolean;
  closing: boolean;
  closed: boolean;
  unavailable: boolean;
  prompt: string;
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
    canonicalRoot: string;
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
  onPromptChange: (value: string) => void;
  onSubmit: () => void;
  onConfirmAccess: () => void;
  onSelectWorkspace: (workspaceId: string) => void;
  onSelectModel: (id: string) => void;
}) {
  const { t } = useI18n();

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea || typeof window === "undefined") return;
    resizeComposerTextarea(textarea);
  }, [prompt, textareaRef]);

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

  return (
    <footer className="composer-bar">
      <div className="composer-shell">
        <div className="composer">
          <textarea
            ref={textareaRef}
            value={prompt}
            maxLength={maxComposerCharacters}
            disabled={composeDisabled}
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
            onChange={(event) => onPromptChange(event.target.value)}
            onKeyDown={(event) => {
              if (
                event.key === "Enter" &&
                !event.shiftKey &&
                !event.nativeEvent.isComposing &&
                canSubmit
              ) {
                event.preventDefault();
                onSubmit();
              }
            }}
          />
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
              className="composer-send focus-ring"
              aria-label={t("run.submit")}
              title={t("run.submit")}
              disabled={!canSubmit}
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
