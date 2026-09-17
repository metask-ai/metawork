import { useEffect, useRef, useState, type ReactNode } from "react";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import type { TaskPanelTab } from "./task-panel-state.ts";

function pathSegments(path: string): string[] {
  return path.split(/[\\/]/).filter(Boolean);
}

export function taskPanelTabLabels(tabs: TaskPanelTab[]): Map<string, string> {
  const labels = new Map<string, string>();
  const previews = tabs.filter((tab) => tab.kind === "preview");
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
  children: ReactNode;
  attention: ReactNode;
  actions?: ReactNode;
  onSelectTab: (tabId: string) => void;
  onCloseTab: (tabId: string) => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const labels = taskPanelTabLabels(tabs);
  const [focusedTabId, setFocusedTabId] = useState(activeTabId);
  const tabButtons = useRef(new Map<string, HTMLButtonElement>());

  useEffect(() => {
    if (
      focusedTabId &&
      tabs.some((candidate) => candidate.tabId === focusedTabId)
    )
      return;
    setFocusedTabId(activeTabId ?? tabs[0]?.tabId ?? null);
  }, [activeTabId, focusedTabId, tabs]);

  useEffect(() => {
    if (!activeTabId) return;
    tabButtons.current.get(activeTabId)?.scrollIntoView({ inline: "nearest" });
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
    tabButtons.current.get(next.tabId)?.focus();
  }

  return (
    <div className="task-panel-frame">
      <header className="task-panel-header">
        <h2
          id="task-panel-title"
          className={tabs.length > 0 ? "sr-only" : undefined}
          tabIndex={-1}
        >
          {title}
        </h2>
        {tabs.length > 0 && (
          <div
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
                    className="task-panel-tab focus-ring"
                    role="tab"
                    aria-selected={active}
                    aria-controls={active ? "task-panel-tabpanel" : undefined}
                    tabIndex={
                      tab.tabId === (focusedTabId ?? activeTabId) ? 0 : -1
                    }
                    title={tab.kind === "preview" ? tab.displayPath : label}
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
        )}
        <div className="task-panel-header-actions">
          {attention}
          {actions}
          <button
            type="button"
            className="task-panel-close focus-ring"
            aria-label={t("task_panel.hide")}
            onClick={onClose}
          >
            <Icon name="close" />
          </button>
        </div>
      </header>
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
    </div>
  );
}
