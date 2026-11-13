import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import type { WorkspaceOpenFailure } from "./useWorkspaceDirectoryOpen.ts";

const messages = {
  workspace_unavailable: "workspace.open_failed.workspace_unavailable",
  directory_unavailable: "workspace.open_failed.directory_unavailable",
  system_open_failed: "workspace.open_failed.system_open_failed",
  request_failed: "workspace.open_failed.request_failed",
} as const satisfies Record<WorkspaceOpenFailure, MessageId>;

export function WorkspaceOpenFailureNotice({
  failure,
  className,
  onDismiss,
}: {
  failure: WorkspaceOpenFailure;
  className: string;
  onDismiss: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className={`workspace-open-failure ${className}`}>
      <span role="alert">{t(messages[failure])}</span>
      <button
        type="button"
        className="icon-button focus-ring"
        aria-label={t("feedback.dismiss")}
        title={t("feedback.dismiss")}
        onClick={onDismiss}
      >
        <Icon name="close" />
      </button>
    </div>
  );
}
