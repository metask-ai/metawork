import { useLayoutEffect, useRef, useState, type RefObject } from "react";

import type { WorkspaceFileReference } from "../../bridge/attachment-receive.ts";
import type { SkillCatalogView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  useWorkspaceFileTree,
  type DirectoryLoader,
} from "../task-panel/WorkspaceFileTree.tsx";
import { resolveSlashCandidates, type SlashCandidate } from "./slash.ts";

export type ComposerWorkspaceFiles = {
  scope: string;
  target: Omit<WorkspaceFileReference, "path">;
  load: DirectoryLoader;
  choose: (reference: WorkspaceFileReference) => void;
};

export function ComposerAddMenu({
  triggerRef,
  disabled,
  attachmentsEnabled,
  skillText,
  skillCatalog,
  onChooseAttachments,
  workspaceFiles,
  onRefreshSkills,
  onChooseSkill,
}: {
  triggerRef: RefObject<HTMLButtonElement | null>;
  disabled: boolean;
  attachmentsEnabled: boolean;
  skillText: string | null;
  skillCatalog: SkillCatalogView;
  onChooseAttachments: () => void;
  workspaceFiles?: ComposerWorkspaceFiles;
  onRefreshSkills: () => void;
  onChooseSkill: (
    candidate: Extract<SlashCandidate, { kind: "skill" }>,
  ) => void;
}) {
  const { t } = useI18n();
  const skills =
    skillText === null
      ? []
      : resolveSlashCandidates({
          input: { query: "", tail: skillText, explicitSkill: true },
          commands: [],
          catalog: skillCatalog,
        }).filter((candidate) => candidate.kind === "skill");
  const catalogUsable =
    skillCatalog.availability === "ready" ||
    skillCatalog.availability === "degraded";

  return (
    <Menu.Root modal={false}>
      <Menu.Trigger
        ref={triggerRef}
        render={
          <Button
            variant="ghost"
            size="icon"
            className="composer-attachment-add"
          />
        }
        aria-label={t("composer.add")}
        title={t("composer.add")}
        disabled={disabled || (!attachmentsEnabled && skillText === null)}
      >
        <Icon name="plus" />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner side="top" align="start">
          <Menu.Popup aria-label={t("composer.add")}>
            {attachmentsEnabled && (
              <Menu.Item onClick={onChooseAttachments}>
                <Icon name="paperclip" />
                {t("attachment.add")}
              </Menu.Item>
            )}
            {workspaceFiles && attachmentsEnabled && (
              <WorkspaceReferenceMenu files={workspaceFiles} />
            )}
            <Menu.SubmenuRoot
              onOpenChange={(open) => {
                if (open) onRefreshSkills();
              }}
            >
              <Menu.SubmenuTrigger
                openOnHover={false}
                disabled={skillText === null}
                title={
                  skillText === null
                    ? t("composer.add_skill_with_attachments")
                    : undefined
                }
              >
                <Icon name="skills" />
                <span className="flex-1">{t("composer.add_skill")}</span>
                <Icon name="chevron-right" />
              </Menu.SubmenuTrigger>
              <Menu.Portal>
                <Menu.Positioner side="right" align="start">
                  <Menu.Popup
                    aria-label={t("composer.add_skill")}
                    className="max-h-[min(320px,var(--available-height))] max-w-[min(280px,calc(100vw-32px))] overflow-y-auto"
                  >
                    {skills.length > 0 ? (
                      skills.map((skill) => (
                        <Menu.Item
                          key={skill.key}
                          onClick={() => onChooseSkill(skill)}
                        >
                          <span
                            className="min-w-0 truncate"
                            title={skill.displayName || skill.invocationName}
                          >
                            {skill.displayName || skill.invocationName}
                          </span>
                        </Menu.Item>
                      ))
                    ) : (
                      <Menu.Item disabled>
                        {t(
                          catalogUsable
                            ? "slash.no_skills"
                            : skillCatalog.availability === "loading"
                              ? "slash.skills_loading"
                              : "slash.skills_unavailable",
                        )}
                      </Menu.Item>
                    )}
                  </Menu.Popup>
                </Menu.Positioner>
              </Menu.Portal>
            </Menu.SubmenuRoot>
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

function WorkspaceReferenceMenu({ files }: { files: ComposerWorkspaceFiles }) {
  const { t } = useI18n();
  const { target } = files;
  const [open, setOpen] = useState(false);
  const [path, setPath] = useState("");
  const popupRef = useRef<HTMLDivElement>(null);
  const focusAfterNavigation = useRef(false);
  const tree = useWorkspaceFileTree(
    open ? files.scope : null,
    target.taskId,
    target.workspaceId,
    target.workspaceEpoch,
    open,
    files.load,
  );
  const directory = Object.hasOwn(tree.directories, path)
    ? tree.directories[path]
    : undefined;
  const entries =
    directory?.state === "ready"
      ? [...directory.entries].sort(
          (left, right) =>
            Number(right.kind === "directory") -
              Number(left.kind === "directory") ||
            left.name.localeCompare(right.name),
        )
      : [];

  function navigate(next: string) {
    focusAfterNavigation.current = true;
    setPath(next);
    if (!Object.hasOwn(tree.directories, next)) tree.request(next);
  }

  useLayoutEffect(() => {
    const popup = popupRef.current;
    if (!open || !popup || !focusAfterNavigation.current) return;
    focusAfterNavigation.current = false;
    popup.scrollTop = 0;
    const firstItem = popup.querySelector<HTMLElement>(
      '[role="menuitem"]:not([data-disabled])',
    );
    (firstItem ?? popup).focus();
  }, [open, path]);

  return (
    <Menu.SubmenuRoot
      onOpenChange={(next) => {
        setOpen(next);
        if (!next) {
          setPath("");
          focusAfterNavigation.current = false;
        }
      }}
    >
      <Menu.SubmenuTrigger openOnHover={false}>
        <Icon name="skill-file" />
        <span className="flex-1">{t("composer.reference_workspace_file")}</span>
        <Icon name="chevron-right" />
      </Menu.SubmenuTrigger>
      <Menu.Portal>
        <Menu.Positioner side="right" align="start">
          <Menu.Popup
            ref={popupRef}
            aria-label={t("composer.reference_workspace_file")}
            className="max-h-[min(320px,var(--available-height))] max-w-[min(280px,calc(100vw-32px))] overflow-y-auto"
          >
            {path && (
              <Menu.Item
                closeOnClick={false}
                title={path}
                onClick={() =>
                  navigate(path.slice(0, Math.max(0, path.lastIndexOf("/"))))
                }
              >
                <Icon name="arrow-left" />
                {t("composer.workspace_parent_folder")}
              </Menu.Item>
            )}
            {entries.map((entry) => {
              const child = path ? `${path}/${entry.name}` : entry.name;
              const folder = entry.kind === "directory";
              return (
                <Menu.Item
                  key={child}
                  closeOnClick={!folder}
                  onClick={() => {
                    if (folder) navigate(child);
                    else files.choose({ ...target, path: child });
                  }}
                >
                  <Icon name={folder ? "workspace" : "skill-file"} />
                  <span className="min-w-0 flex-1 truncate" title={entry.name}>
                    {entry.name}
                  </span>
                  {folder && <Icon name="chevron-right" />}
                </Menu.Item>
              );
            })}
            {!directory && tree.capacity ? (
              <>
                <Menu.Item disabled>
                  {t("task_panel.directory_capacity")}
                </Menu.Item>
                <Menu.Item
                  closeOnClick={false}
                  onClick={() => {
                    focusAfterNavigation.current = true;
                    setPath("");
                    tree.refresh();
                  }}
                >
                  {t("task_panel.refresh_directory")}
                </Menu.Item>
              </>
            ) : !directory || directory.state === "loading" ? (
              <Menu.Item disabled>{t("common.loading")}</Menu.Item>
            ) : directory.state !== "ready" ? (
              <>
                <Menu.Item disabled>
                  {t(
                    directory.state === "missing"
                      ? "file_preview.state.missing"
                      : directory.state === "restricted"
                        ? "file_preview.state.restricted"
                        : "file_preview.state.error",
                  )}
                </Menu.Item>
                <Menu.Item
                  closeOnClick={false}
                  onClick={() => {
                    popupRef.current?.focus();
                    tree.request(path);
                  }}
                >
                  {t("task_panel.retry_directory")}
                </Menu.Item>
              </>
            ) : (
              <>
                {entries.length === 0 && (
                  <Menu.Item disabled>
                    {t("task_panel.directory_empty")}
                  </Menu.Item>
                )}
                {(directory.truncated || directory.redacted) && (
                  <Menu.Item disabled>
                    {t(
                      directory.truncated
                        ? "task_panel.directory_truncated"
                        : "task_panel.directory_redacted",
                    )}
                  </Menu.Item>
                )}
              </>
            )}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.SubmenuRoot>
  );
}
