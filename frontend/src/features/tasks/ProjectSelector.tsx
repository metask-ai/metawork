import type { WorkspaceView } from "../../bridge/contracts.ts";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { orderedProjects } from "../../workbench/selectors.ts";

export function ProjectSelector({
  projectId,
  workspaces,
  disabled,
  onSelect,
}: {
  projectId: string | null;
  workspaces: readonly WorkspaceView[];
  disabled: boolean;
  onSelect: (projectId: string | null) => void;
}) {
  const { t } = useI18n();
  const projects = orderedProjects(workspaces);
  const selected = projects.find((project) => project.id === projectId);
  return (
    <SelectionMenu
      value={projectId ?? "none"}
      options={[
        { value: "none", label: t("task.no_project") },
        ...projects.map((project) => ({
          value: project.id,
          label: project.displayName,
        })),
      ]}
      placeholder={
        projectId === null
          ? t("task.no_project")
          : (selected?.displayName ?? t("task.project_removed"))
      }
      ariaLabel={t("task.project")}
      disabled={disabled}
      compact
      leading={<Icon name="workspace" />}
      onValueChange={(value) => onSelect(value === "none" ? null : value)}
    />
  );
}
