import { useLayoutEffect, useRef, useState } from "react";

import type { WorkspaceFileReference } from "../../bridge/attachment-receive.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  useWorkspaceFileTree,
  type DirectoryLoader,
} from "./WorkspaceFileTree.tsx";

type WorkspaceReferenceFiles = {
  scope: string;
  target: Omit<WorkspaceFileReference, "path">;
  load: DirectoryLoader;
  choose: (reference: WorkspaceFileReference) => void;
};

export function WorkspaceReferenceMenu({
  files,
}: {
  files: WorkspaceReferenceFiles;
}) {
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
