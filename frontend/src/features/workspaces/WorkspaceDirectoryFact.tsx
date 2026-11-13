import { useRef } from "react";
import type {
  WorkspaceOpenResult,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { useWorkspaceDirectoryOpen } from "./useWorkspaceDirectoryOpen.ts";
import { WorkspaceOpenFailureNotice } from "./WorkspaceOpenFailureNotice.tsx";

export function WorkspaceDirectoryFact({
  workspace,
  onOpen,
  disabled = false,
}: {
  workspace?: WorkspaceView;
  onOpen?: () => Promise<WorkspaceOpenResult>;
  disabled?: boolean;
}) {
  const { t } = useI18n();
  const openButton = useRef<HTMLButtonElement>(null);
  const { cannotOpen, openDirectory, openFailure, dismissOpenFailure } =
    useWorkspaceDirectoryOpen(workspace, onOpen, disabled);
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
            ref={openButton}
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
        {openFailure && (
          <WorkspaceOpenFailureNotice
            failure={openFailure}
            className="task-workspace-error"
            onDismiss={() => {
              dismissOpenFailure();
              openButton.current?.focus();
            }}
          />
        )}
      </dd>
    </div>
  );
}
