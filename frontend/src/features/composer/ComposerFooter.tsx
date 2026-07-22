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
  actionDisabled,
  onPromptChange,
  onSubmit,
  onConfirmAccess,
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
  actionDisabled: boolean;
  onPromptChange: (value: string) => void;
  onSubmit: () => void;
  onConfirmAccess: () => void;
}) {
  const { t } = useI18n();
  return (
    <footer className="composer-bar">
      <div className="composer-context" aria-label={t("run.context")}>
        {modelLabel && (
          <>
            <span className="composer-context-item">
              <small>{t("account.model")}</small>
              <strong>{modelLabel}</strong>
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
