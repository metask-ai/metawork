import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { Icon } from "../../components/ui/Icon.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";
import type { TaskPanelTab } from "./task-panel-state.ts";

function pathSegments(path: string): string[] {
  return path.split(/[\\/]/).filter(Boolean);
}

function revealTaskPanelTab(list: HTMLElement, tab: HTMLElement): void {
  const listRect = list.getBoundingClientRect();
  const tabRect = tab.getBoundingClientRect();
  if (tabRect.left < listRect.left)
    list.scrollLeft -= listRect.left - tabRect.left;
  else if (tabRect.right > listRect.right)
    list.scrollLeft += tabRect.right - listRect.right;
}

export function taskPanelTabLabels(tabs: TaskPanelTab[]): Map<string, string> {
  const labels = new Map<string, string>();
  const previews = tabs.filter((tab) => tab.kind !== "review");
  for (const tab of previews) {
    const fallback = pathSegments(tab.displayPath).at(-1) ?? tab.displayPath;
    const base = tab.title || fallback;
    const peers = previews.filter(
      (candidate) =>
        (candidate.title || pathSegments(candidate.displayPath).at(-1)) ===
        base,
    );
    if (peers.length === 1) {
      labels.set(tab.tabId, base);
      continue;
    }
    const segments = pathSegments(tab.displayPath);
    let label = tab.displayPath;
    for (let length = 2; length <= segments.length; length += 1) {
      const suffix = segments.slice(-length).join("/");
      if (
        peers.every(
          (candidate) =>
            candidate.tabId === tab.tabId ||
            pathSegments(candidate.displayPath).slice(-length).join("/") !==
              suffix,
        )
      ) {
        label = suffix;
        break;
      }
    }
    const identical = peers.filter(
      (candidate) => candidate.displayPath === tab.displayPath,
    );
    if (identical.length > 1)
      label = `${label} · ${identical.findIndex((candidate) => candidate.tabId === tab.tabId) + 1}`;
    labels.set(tab.tabId, label);
  }
  return labels;
}

export function TaskPanel({
  title,
  tabs,
  activeTabId,
  fileTreeOpen,
  onToggleFileTree,
  fileTree,
  children,
  attention,
  actions,
  onSelectTab,
  onCloseTab,
  onClose,
}: {
  title: string;
  tabs: TaskPanelTab[];
  activeTabId: string | null;
  fileTreeOpen: boolean;
  onToggleFileTree: () => void;
  fileTree?: ReactNode;
  children: ReactNode;
  attention: ReactNode;
  actions?: ReactNode;
  onSelectTab: (tabId: string) => void;
  onCloseTab: (tabId: string) => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const labels = taskPanelTabLabels(tabs);
  const fileTreeToggleLabel = t(
    fileTreeOpen ? "task_panel.hide_file_tree" : "task_panel.show_file_tree",
  );
  const [focusedTabId, setFocusedTabId] = useState(activeTabId);
  const tabList = useRef<HTMLDivElement | null>(null);
  const tabButtons = useRef(new Map<string, HTMLButtonElement>());

  function revealTab(tabId: string) {
    const list = tabList.current;
    const tab = tabButtons.current.get(tabId)?.parentElement;
    if (!list || !tab) return;
    revealTaskPanelTab(list, tab);
  }

  useEffect(() => {
    if (
      focusedTabId &&
      tabs.some((candidate) => candidate.tabId === focusedTabId)
    )
      return;
    setFocusedTabId(activeTabId ?? tabs[0]?.tabId ?? null);
  }, [activeTabId, focusedTabId, tabs]);

  useLayoutEffect(() => {
    if (!activeTabId) return;
    revealTab(activeTabId);
  }, [activeTabId]);

  function labelFor(tab: TaskPanelTab): string {
    return tab.kind === "review"
      ? t("file_changes.review")
      : (labels.get(tab.tabId) ?? tab.displayPath);
  }

  function moveTabFocus(currentTabId: string, key: string) {
    const index = tabs.findIndex((tab) => tab.tabId === currentTabId);
    if (index < 0) return;
    const nextIndex =
      key === "Home"
        ? 0
        : key === "End"
          ? tabs.length - 1
          : key === "ArrowLeft"
            ? (index - 1 + tabs.length) % tabs.length
            : key === "ArrowRight"
              ? (index + 1) % tabs.length
              : index;
    const next = tabs[nextIndex];
    if (!next || next.tabId === currentTabId) return;
    setFocusedTabId(next.tabId);
    revealTab(next.tabId);
    tabButtons.current.get(next.tabId)?.focus({ preventScroll: true });
  }

  return (
    <div className="task-panel-frame">
      <header className="task-panel-header">
        <h2 id="task-panel-title" className="sr-only">
          {title}
        </h2>
        {tabs.length > 0 ? (
          <div
            ref={tabList}
            className="task-panel-tabs"
            role="tablist"
            aria-label={t("task_panel.tabs")}
          >
            {tabs.map((tab, index) => {
              const active = tab.tabId === activeTabId;
              const label = labelFor(tab);
              const tabDomId = `task-panel-tab-${index}`;
              return (
                <div
                  className="task-panel-tab-item"
                  data-active={active}
                  key={tab.tabId}
                >
                  <button
                    ref={(element) => {
                      if (element) tabButtons.current.set(tab.tabId, element);
                      else tabButtons.current.delete(tab.tabId);
                    }}
                    type="button"
                    id={tabDomId}
                    data-task-panel-tab-id={tab.tabId}
                    className="task-panel-tab focus-ring"
                    role="tab"
                    aria-selected={active}
                    aria-controls="task-panel-tabpanel"
                    tabIndex={
                      tab.tabId === (focusedTabId ?? activeTabId) ? 0 : -1
                    }
                    title={tab.kind !== "review" ? tab.displayPath : label}
                    onFocus={() => setFocusedTabId(tab.tabId)}
                    onClick={() => onSelectTab(tab.tabId)}
                    onKeyDown={(event) => {
                      if (
                        !["ArrowLeft", "ArrowRight", "Home", "End"].includes(
                          event.key,
                        )
                      )
                        return;
                      event.preventDefault();
                      moveTabFocus(tab.tabId, event.key);
                    }}
                  >
                    <Icon
                      name={tab.kind === "review" ? "file-diff" : "skill-file"}
                    />
                    <span>{label}</span>
                  </button>
                  <button
                    type="button"
                    className="task-panel-tab-close focus-ring"
                    aria-label={t("task_panel.close_tab", { title: label })}
                    onClick={() => onCloseTab(tab.tabId)}
                  >
                    <Icon name="close" />
                  </button>
                </div>
              );
            })}
          </div>
        ) : (
          <div className="task-panel-header-spacer" />
        )}
        <div className="task-panel-header-actions">
          {tabs.length > 0 && attention}
          {tabs.length > 0 && (
            <span className="task-panel-context-action-slot">{actions}</span>
          )}
          <Tooltip.Root>
            <Tooltip.Trigger
              render={
                <button
                  type="button"
                  className="task-panel-header-action task-panel-file-tree-toggle focus-ring"
                  aria-label={fileTreeToggleLabel}
                  aria-expanded={fileTreeOpen}
                  aria-controls="task-panel-file-tree"
                  onClick={onToggleFileTree}
                />
              }
            >
              <Icon name="file-tree" />
            </Tooltip.Trigger>
            <Tooltip.Portal>
              <Tooltip.Positioner side="bottom" align="end">
                <Tooltip.Popup>{fileTreeToggleLabel}</Tooltip.Popup>
              </Tooltip.Positioner>
            </Tooltip.Portal>
          </Tooltip.Root>
          {tabs.length > 0 && (
            <button
              type="button"
              className="task-panel-close focus-ring"
              aria-label={t("task_panel.hide")}
              onClick={onClose}
            >
              <Icon name="close" />
            </button>
          )}
        </div>
      </header>
      <div className="task-panel-body">
        {activeTabId ? (
          <div
            id="task-panel-tabpanel"
            className="task-panel-content"
            role="tabpanel"
            aria-labelledby={`task-panel-tab-${tabs.findIndex((tab) => tab.tabId === activeTabId)}`}
          >
            {children}
          </div>
        ) : (
          <div className="task-panel-content">{children}</div>
        )}
        {fileTreeOpen && (
          <aside
            id="task-panel-file-tree"
            className="task-panel-file-tree"
            aria-label={t("task_panel.file_tree")}
          >
            <h3 className="task-panel-file-tree-heading">
              <Icon name="workspace" />
              {t("task_panel.file_tree")}
            </h3>
            {fileTree}
          </aside>
        )}
      </div>
    </div>
  );
}
