import type { KeyboardEvent, ReactNode } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import type {
  TaskPanelResourceTarget,
  TaskPanelTab,
} from "./task-panel-state.ts";

function resourceName(path: string) {
  const segments = path.split(/[\\/]/);
  return segments.at(-1) || path;
}

function moveTabFocus(event: KeyboardEvent<HTMLButtonElement>) {
  if (
    event.key !== "ArrowLeft" &&
    event.key !== "ArrowRight" &&
    event.key !== "Home" &&
    event.key !== "End"
  )
    return;
  const tablist = event.currentTarget.closest('[role="tablist"]');
  const tabs = tablist
    ? Array.from(tablist.querySelectorAll<HTMLButtonElement>('[role="tab"]'))
    : [];
  if (tabs.length === 0) return;
  const current = tabs.indexOf(event.currentTarget);
  if (current < 0) return;
  event.preventDefault();
  const next =
    event.key === "Home"
      ? 0
      : event.key === "End"
        ? tabs.length - 1
        : event.key === "ArrowRight"
          ? (current + 1) % tabs.length
          : (current - 1 + tabs.length) % tabs.length;
  tabs[next]?.focus();
}

export function TaskPanel({
  activeTab,
  resource,
  hasReview,
  hasAttention,
  overview,
  review,
  resourceView,
  onActivate,
  onCloseReview,
  onCloseResource,
  onClose,
}: {
  activeTab: TaskPanelTab;
  resource: TaskPanelResourceTarget | null;
  hasReview: boolean;
  hasAttention: boolean;
  overview: ReactNode;
  review: ReactNode;
  resourceView: ReactNode;
  onActivate: (tab: TaskPanelTab) => void;
  onCloseReview: () => void;
  onCloseResource: () => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="task-panel-frame">
      <h2 id="task-panel-title" className="sr-only" tabIndex={-1}>
        {t("task_panel.title")}
      </h2>
      <header className="task-panel-tabbar">
        <div
          className="task-panel-tabs"
          role="tablist"
          aria-label={t("task_panel.title")}
        >
          <button
            id="task-panel-overview-tab"
            type="button"
            role="tab"
            className="task-panel-root-tab focus-ring"
            aria-selected={activeTab === "overview"}
            aria-controls="task-panel-content"
            tabIndex={activeTab === "overview" ? 0 : -1}
            onKeyDown={moveTabFocus}
            onClick={() => onActivate("overview")}
          >
            <Icon name="activity" />
            {t("task_panel.overview")}
            {hasAttention && activeTab !== "overview" && (
              <span
                className="task-panel-attention-dot"
                aria-label={t("inspector.needs_attention")}
              />
            )}
          </button>

          {hasReview && (
            <div
              className="task-panel-tab-group"
              data-active={activeTab === "review"}
            >
              <button
                id="task-panel-review-tab"
                type="button"
                role="tab"
                className="task-panel-root-tab focus-ring"
                aria-selected={activeTab === "review"}
                aria-controls="task-panel-content"
                tabIndex={activeTab === "review" ? 0 : -1}
                onKeyDown={moveTabFocus}
                onClick={() => onActivate("review")}
              >
                <Icon name="file-diff" />
                {t("task_panel.review")}
              </button>
              <button
                type="button"
                className="task-panel-tab-close focus-ring"
                aria-label={t("task_panel.close_review")}
                onClick={onCloseReview}
              >
                <Icon name="close" />
              </button>
            </div>
          )}

          {resource && (
            <div
              className="task-panel-tab-group task-panel-resource-tab"
              data-active={activeTab === "resource"}
            >
              <button
                id="task-panel-resource-tab"
                type="button"
                role="tab"
                className="task-panel-resource-tab-button focus-ring"
                aria-selected={activeTab === "resource"}
                aria-controls="task-panel-content"
                tabIndex={activeTab === "resource" ? 0 : -1}
                title={resource.displayPath}
                onKeyDown={moveTabFocus}
                onClick={() => onActivate("resource")}
              >
                <Icon
                  name={resource.kind === "diff" ? "file-diff" : "skill-file"}
                />
                <span>{resourceName(resource.displayPath)}</span>
              </button>
              <button
                type="button"
                className="task-panel-tab-close focus-ring"
                aria-label={t("task_panel.close_resource", {
                  path: resource.displayPath,
                })}
                onClick={onCloseResource}
              >
                <Icon name="close" />
              </button>
            </div>
          )}
        </div>

        <button
          type="button"
          className="task-panel-close focus-ring"
          aria-label={t("task_panel.close")}
          onClick={() => onClose()}
        >
          <Icon name="close" />
        </button>
      </header>

      <div
        id="task-panel-content"
        className="task-panel-content"
        role="tabpanel"
        aria-labelledby={`task-panel-${activeTab}-tab`}
      >
        {activeTab === "overview"
          ? overview
          : activeTab === "review"
            ? review
            : resourceView}
      </div>
    </div>
  );
}
