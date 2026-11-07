import type { WorkspaceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { useWorkspaceDirectoryOpen } from "./useWorkspaceDirectoryOpen.ts";

export function WorkspaceDirectoryFact({
  workspace,
  onOpen,
  disabled = false,
}: {
  workspace?: WorkspaceView;
  onOpen?: () => Promise<{ opened: boolean }>;
  disabled?: boolean;
}) {
  const { t } = useI18n();
  const { cannotOpen, openDirectory, openFailed } = useWorkspaceDirectoryOpen(
    workspace,
    onOpen,
    disabled,
  );
  if (
    workspace?.kind !== "manual" ||
    workspace.redacted ||
    !workspace.displayName
  )
    return null;
  const workspaceName = workspace.displayName;
  return (
    <div className="task-workspace-fact">
      <dt>{t("workspace.working_directory")}</dt>
      <dd>
        <div className="task-workspace-directory">
          <span>{workspaceName}</span>
          <button
            type="button"
            className="icon-button focus-ring"
            aria-label={t("workspace.open")}
            title={t("workspace.open")}
            disabled={cannotOpen}
            onClick={() => void openDirectory()}
          >
            <Icon name="folder-open" />
          </button>
        </div>
        {openFailed && (
          <small className="task-workspace-error" role="alert">
            {t("workspace.open_failed")}
          </small>
        )}
      </dd>
    </div>
  );
}
