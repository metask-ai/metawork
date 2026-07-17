import type { RefObject } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { maxComposerCharacters } from "./drafts.ts";

export function ComposerFooter({
  textareaRef,
  hasTask,
  draft,
  archived,
  closed,
  prompt,
  composeDisabled,
  canSubmit,
  runInFlight,
  accessRequired,
  actionDisabled,
  onStart,
  onPromptChange,
  onSubmit,
  onConfirmAccess,
}: {
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  hasTask: boolean;
  draft: boolean;
  archived: boolean;
  closed: boolean;
  prompt: string;
  composeDisabled: boolean;
  canSubmit: boolean;
  runInFlight: boolean;
  accessRequired: boolean;
  actionDisabled: boolean;
  onStart: () => void;
  onPromptChange: (value: string) => void;
  onSubmit: () => void;
  onConfirmAccess: () => void;
}) {
  const { t } = useI18n();
  return (
    <footer className="composer-bar">
      {!hasTask && !draft ? (
        <button
          className="composer-start focus-ring"
          disabled={actionDisabled}
          onClick={onStart}
        >
          <Icon name="workspace" />
          <span>
            <strong>{t("task.start_new")}</strong>
            <small>{t("task.start_new_help")}</small>
          </span>
        </button>
      ) : (
        <>
          <div className="composer">
            <textarea
              ref={textareaRef}
              value={prompt}
              maxLength={maxComposerCharacters}
              disabled={composeDisabled}
              placeholder={
                archived
                  ? t("run.placeholder_archived")
                  : closed
                    ? t("run.placeholder_closed")
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
        </>
      )}
      {runInFlight && (
        <p className="composer-draft-note">{t("run.draft_only")}</p>
      )}
    </footer>
  );
}
