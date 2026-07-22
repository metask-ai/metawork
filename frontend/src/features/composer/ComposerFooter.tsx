import type { RefObject } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { maxComposerCharacters } from "./drafts.ts";

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
  onSelectModel,
  onOpenModelSettings,
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
  onSelectModel: (id: string) => void;
  onOpenModelSettings: () => void;
}) {
  const { t } = useI18n();
  return (
    <footer className="composer-bar">
      <div className="composer-context" aria-label={t("run.context")}>
        {modelLabel && (
          <>
            <span className="composer-context-item composer-model-context">
              <small>{t("account.model")}</small>
              {modelEditable ? (
                <span className="composer-model-controls">
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
                  <button
                    className="composer-settings-link focus-ring"
                    aria-label={t("settings.open_account_models")}
                    title={t("settings.open_account_models")}
                    onClick={onOpenModelSettings}
                  >
                    <Icon name="settings" />
                  </button>
                </span>
              ) : (
                <strong title={modelContextTitle}>{modelLabel}</strong>
              )}
            </span>
            <span className="composer-context-divider" aria-hidden="true" />
          </>
        )}
        <span className="composer-context-item">
          <small>{t("workspace.label")}</small>
          {workspaceMissing ? (
            <button
              className="composer-context-action focus-ring"
              disabled={actionDisabled}
              onClick={onConfirmAccess}
            >
              {t("workspace.choose_on_send")}
            </button>
          ) : (
            <strong title={workspaceTitle}>{workspaceLabel}</strong>
          )}
        </span>
      </div>
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
      {accessRequired && (
        <p className="composer-access-note">
          <span>{t("workspace.access_required")}</span>
          <button
            className="text-button focus-ring"
            disabled={actionDisabled}
            onClick={onConfirmAccess}
          >
            {t("workspace.confirm_access")}
          </button>
        </p>
      )}
      {runInFlight && (
        <p className="composer-draft-note">{t("run.draft_only")}</p>
      )}
    </footer>
  );
}
