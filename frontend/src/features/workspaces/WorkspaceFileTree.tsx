import { useEffect, useId, useRef, useState } from "react";
import type {
  FilePreviewLoadOptions,
  WorkspaceDirectory,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

type DirectoryState = { state: "loading" } | WorkspaceDirectory;
export type DirectoryLoader = (
  taskId: string | null,
  workspaceId: string,
  workspaceEpoch: string,
  path: string,
  options?: FilePreviewLoadOptions,
) => Promise<WorkspaceDirectory>;

export function useWorkspaceFileTree(
  scope: string | null,
  taskId: string | null,
  workspaceId: string | null,
  workspaceEpoch: string | null,
  visible: boolean,
  load: DirectoryLoader,
) {
  const [stored, setStored] = useState<{
    scope: string | null;
    directories: Record<string, DirectoryState>;
    expanded: Set<string>;
  }>({ scope: null, directories: {}, expanded: new Set() });
  const active = useRef(scope);
  active.current = scope;
  const requests = useRef(new Map<string, AbortController>());
  const admitted = useRef(new Set<string>());
  const directories = stored.scope === scope ? stored.directories : {};
  const expanded = stored.scope === scope ? stored.expanded : new Set<string>();
  function cancel() {
    for (const request of requests.current.values()) request.abort();
    requests.current.clear();
  }
  useEffect(() => {
    cancel();
    admitted.current.clear();
    setStored({ scope, directories: {}, expanded: new Set() });
    return cancel;
  }, [scope]);
  function request(path: string) {
    if (!scope || !workspaceId || !workspaceEpoch || requests.current.has(path))
      return;
    if (admitted.current.size >= 64 && !admitted.current.has(path)) return;
    admitted.current.add(path);
    const controller = new AbortController();
    requests.current.set(path, controller);
    setStored((current) => ({
      scope,
      expanded: current.scope === scope ? current.expanded : new Set(),
      directories: {
        ...(current.scope === scope ? current.directories : {}),
        [path]: { state: "loading" },
      },
    }));
    void load(taskId, workspaceId, workspaceEpoch, path, {
      signal: controller.signal,
      priority: "interactive",
    })
      .catch((): WorkspaceDirectory => ({
        state: "error",
        entries: [],
        truncated: false,
        redacted: false,
      }))
      .then((result) => {
        if (
          controller.signal.aborted ||
          active.current !== scope ||
          requests.current.get(path) !== controller
        )
          return;
        requests.current.delete(path);
        setStored((current) =>
          current.scope === scope
            ? {
                ...current,
                directories: { ...current.directories, [path]: result },
              }
            : current,
        );
      });
  }
  useEffect(() => {
    if (visible && scope && !directories[""]) request("");
  }, [visible, scope, directories[""]]);
  function toggle(path: string) {
    setStored((current) => {
      const next = new Set(current.scope === scope ? current.expanded : []);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return {
        scope,
        directories: current.scope === scope ? current.directories : {},
        expanded: next,
      };
    });
    if (!expanded.has(path) && !directories[path]) request(path);
  }
  function refresh() {
    cancel();
    admitted.current.clear();
    setStored({ scope, directories: {}, expanded: new Set() });
  }
  return {
    directories,
    expanded,
    request,
    toggle,
    refresh,
    capacity: stored.scope === scope && admitted.current.size >= 64,
  };
}

export function WorkspaceFileTree({
  tree,
  available,
  selectedPath,
  onOpen,
}: {
  tree: ReturnType<typeof useWorkspaceFileTree>;
  available: boolean;
  selectedPath: string | null;
  onOpen: (path: string, opener: HTMLButtonElement) => void;
}) {
  const { t } = useI18n();
  const treeId = useId();
  const [focused, setFocused] = useState<string | null>(null);
  function renderDirectory(path: string, depth: number) {
    const directory = tree.directories[path];
    if (!directory || directory.state === "loading")
      return (
        <li role="none">
          <p className="task-panel-tree-notice" role="status">
            {t(
              !directory && tree.capacity
                ? "task_panel.directory_capacity"
                : "common.loading",
            )}
          </p>
        </li>
      );
    if (directory.state !== "ready")
      return (
        <li role="none">
          <p className="task-panel-tree-notice" role="status">
            {t(
              directory.state === "missing"
                ? "file_preview.state.missing"
                : directory.state === "restricted"
                  ? "file_preview.state.restricted"
                  : "file_preview.state.error",
            )}
          </p>
          <button
            className="task-panel-tree-retry focus-ring"
            type="button"
            onClick={() => tree.request(path)}
          >
            {t("task_panel.retry_directory")}
          </button>
        </li>
      );
    const entries = [...directory.entries].sort(
      (a, b) =>
        Number(b.kind === "directory") - Number(a.kind === "directory") ||
        a.name.localeCompare(b.name),
    );
    return (
      <>
        {entries.map((entry, index) => {
          const child = path ? `${path}/${entry.name}` : entry.name;
          const folder = entry.kind === "directory";
          const open = tree.expanded.has(child);
          return (
            <li role="none" key={child}>
              <button
                type="button"
                role="treeitem"
                data-path={child}
                data-parent={path}
                aria-level={depth}
                aria-selected={!folder && child === selectedPath}
                aria-expanded={folder ? open : undefined}
                aria-owns={
                  folder && open
                    ? `${treeId}-${encodeURIComponent(child)}`
                    : undefined
                }
                tabIndex={
                  focused === child ||
                  (focused === null && depth === 1 && index === 0)
                    ? 0
                    : -1
                }
                className="task-panel-tree-entry focus-ring"
                title={child}
                onFocus={() => setFocused(child)}
                onClick={(event) =>
                  folder
                    ? tree.toggle(child)
                    : onOpen(child, event.currentTarget)
                }
              >
                <span
                  className="task-panel-tree-indent"
                  style={{ width: (depth - 1) * 12 }}
                />
                <span className="task-panel-tree-chevron" data-expanded={open}>
                  {folder && <Icon name="chevron-right" />}
                </span>
                <Icon name={folder ? "workspace" : "skill-file"} />
                <span className="task-panel-tree-name">{entry.name}</span>
              </button>
              {folder && open && (
                <ul role="group" id={`${treeId}-${encodeURIComponent(child)}`}>
                  {renderDirectory(child, depth + 1)}
                </ul>
              )}
            </li>
          );
        })}
        {entries.length === 0 && (
          <li role="none">
            <p className="task-panel-tree-notice">
              {t("task_panel.directory_empty")}
            </p>
          </li>
        )}
        {(directory.truncated || directory.redacted) && (
          <li role="none">
            <p className="task-panel-tree-notice">
              {t(
                directory.truncated
                  ? "task_panel.directory_truncated"
                  : "task_panel.directory_redacted",
              )}
            </p>
          </li>
        )}
      </>
    );
  }
  return (
    <>
      {available ? (
        <>
          <button
            type="button"
            className="task-panel-tree-refresh focus-ring"
            aria-label={t("task_panel.refresh_directory")}
            title={t("task_panel.refresh_directory")}
            onClick={() => {
              setFocused(null);
              tree.refresh();
            }}
          >
            <Icon name="refresh" />
          </button>
          <ul
            role="tree"
            aria-label={t("task_panel.file_tree")}
            onKeyDown={(event) => {
              const item = (
                event.target as HTMLElement
              ).closest<HTMLButtonElement>('[role="treeitem"]');
              if (!item) return;
              const items = [
                ...event.currentTarget.querySelectorAll<HTMLButtonElement>(
                  '[role="treeitem"]',
                ),
              ];
              const index = items.indexOf(item);
              let next: HTMLButtonElement | undefined;
              if (event.key === "ArrowDown")
                next = items[Math.min(index + 1, items.length - 1)];
              else if (event.key === "ArrowUp")
                next = items[Math.max(index - 1, 0)];
              else if (event.key === "Home") next = items[0];
              else if (event.key === "End") next = items.at(-1);
              else if (
                event.key === "ArrowRight" &&
                item.hasAttribute("aria-expanded")
              ) {
                if (item.getAttribute("aria-expanded") === "false")
                  tree.toggle(item.dataset.path!);
                else next = items[index + 1];
              } else if (event.key === "ArrowLeft") {
                if (item.getAttribute("aria-expanded") === "true")
                  tree.toggle(item.dataset.path!);
                else
                  next = items.find(
                    (candidate) =>
                      candidate.dataset.path === item.dataset.parent,
                  );
              } else return;
              event.preventDefault();
              next?.focus();
            }}
          >
            {renderDirectory("", 1)}
          </ul>
          {tree.capacity && (
            <p className="task-panel-tree-notice">
              {t("task_panel.directory_capacity")}
            </p>
          )}
        </>
      ) : (
        <p className="task-panel-file-tree-empty">
          {t("task_panel.directory_unavailable")}
        </p>
      )}
    </>
  );
}
