import { useEffect, type RefObject } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { maxComposerCharacters } from "./drafts.ts";

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
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
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
              if (event.key === "Enter" && !event.shiftKey && canSubmit) {
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
                {modelEditable ? (
                  <select
                    className="composer-model-select focus-ring"
                    aria-label={t("settings.default_model")}
                    title={modelContextTitle}
                    value={selectedModelId}
                    disabled={modelSelectionDisabled}
                    onChange={(event) => onSelectModel(event.target.value)}
                  >
                    {!modelOptions.some(
                      (model) => model.selectionId === selectedModelId,
                    ) && <option value="">{t("account.choose_model")}</option>}
                    {modelOptions.map((model) => (
                      <option key={model.selectionId} value={model.selectionId}>
                        {model.displayName || t("account.model_fallback")}
                      </option>
                    ))}
                  </select>
                ) : (
                  <strong title={modelContextTitle}>{modelLabel}</strong>
                )}
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
        <div
          className="composer-workspace-context"
          data-state={
            workspaceMissing
              ? "missing"
              : accessRequired
                ? "reauthorization-required"
                : "ready"
          }
          role="group"
          aria-label={t("workspace.label")}
        >
          <span className="composer-workspace-identity">
            <Icon name="workspace" />
            {workspaceEditable ? (
              <select
                className="composer-workspace-select focus-ring"
                aria-label={t("workspace.switch")}
                value={selectedWorkspaceId}
                disabled={actionDisabled || workspaceOptions.length === 0}
                onChange={(event) => onSelectWorkspace(event.target.value)}
              >
                <option value="" disabled>
                  {t("workspace.select")}
                </option>
                {workspaceOptions.map((workspace) => (
                  <option
                    key={workspace.id}
                    value={workspace.id}
                    disabled={workspace.authorization !== "available"}
                    title={workspace.canonicalRoot}
                  >
                    {workspace.label}
                  </option>
                ))}
              </select>
            ) : (
              <strong title={workspaceTitle}>{workspaceLabel}</strong>
            )}
          </span>
          {workspaceEditable && (
            <button
              className="composer-workspace-action focus-ring"
              data-emphasis={accessRequired}
              aria-label={
                accessRequired
                  ? t("workspace.confirm_access")
                  : t("workspace.add")
              }
              title={
                accessRequired
                  ? t("workspace.confirm_access")
                  : t("workspace.add")
              }
              disabled={actionDisabled}
              onClick={onConfirmAccess}
            >
              <Icon name={accessRequired ? "warning" : "plus"} />
              {accessRequired && <span>{t("workspace.confirm_access")}</span>}
            </button>
          )}
        </div>
      </div>
      {runInFlight && (
        <p className="composer-draft-note">{t("run.draft_only")}</p>
      )}
    </footer>
  );
}
