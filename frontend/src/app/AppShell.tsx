import { useEffect, useState, type ReactNode } from "react";

import { Icon } from "../components/ui/Icon.tsx";
import { useI18n } from "../i18n/context.ts";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../platform/local-preferences.ts";
import { primaryShortcutModifier } from "../platform/keyboard.ts";

const leftPreference = "metawork.panel.workspaces";
const rightPreference = "metawork.panel.activity";

function initialPanel(key: string, minimumWidth: number) {
  if (typeof window === "undefined") return true;
  const stored = readLocalPreference(key);
  return window.innerWidth >= minimumWidth && stored !== "closed";
}

export function AppShell({
  taskTitle,
  workspaceLabel,
  status,
  onSearch,
  left,
  activity,
  children,
}: {
  taskTitle: string;
  workspaceLabel: string;
  status: string;
  onSearch: () => void;
  left: ReactNode;
  activity: ReactNode | null;
  children: ReactNode;
}) {
  const { t } = useI18n();
  const shortcutModifier = primaryShortcutModifier();
  const [leftOpen, setLeftOpen] = useState(() =>
    initialPanel(leftPreference, 820),
  );
  const [rightOpen, setRightOpen] = useState(() =>
    initialPanel(rightPreference, 1101),
  );
  const rightAvailable = activity !== null;
  const effectiveRightOpen = rightAvailable && rightOpen;

  useEffect(() => {
    const narrow = window.matchMedia("(max-width: 819px)");
    const medium = window.matchMedia("(max-width: 1100px)");
    const closeForViewport = () => {
      if (narrow.matches) setLeftOpen(false);
      if (medium.matches) setRightOpen(false);
    };
    narrow.addEventListener("change", closeForViewport);
    medium.addEventListener("change", closeForViewport);
    return () => {
      narrow.removeEventListener("change", closeForViewport);
      medium.removeEventListener("change", closeForViewport);
    };
  }, []);

  function toggleLeft() {
    setLeftOpen((open) => {
      const next = !open;
      if (next && window.innerWidth < 820) setRightOpen(false);
      writeLocalPreference(leftPreference, next ? "open" : "closed");
      return next;
    });
  }

  function toggleRight() {
    setRightOpen((open) => {
      const next = !open;
      if (next && window.innerWidth < 820) setLeftOpen(false);
      writeLocalPreference(rightPreference, next ? "open" : "closed");
      return next;
    });
  }

  return (
    <main
      className="app-window"
      data-left-open={leftOpen}
      data-right-open={effectiveRightOpen}
    >
      <header className="app-titlebar">
        <button
          className="icon-button focus-ring"
          aria-controls="workspace-sidebar"
          aria-expanded={leftOpen}
          aria-label={t("app.toggle_workspaces")}
          title={t("app.toggle_workspaces")}
          onClick={toggleLeft}
        >
          <Icon name="sidebar" />
        </button>
        <div className="titlebar-identity">
          <span className="titlebar-task">{taskTitle}</span>
          <span className="titlebar-workspace">{workspaceLabel}</span>
        </div>
        <p className="titlebar-status" aria-live="polite">
          {status}
        </p>
        <button
          className="titlebar-search focus-ring"
          aria-label={t("search.open")}
          title={t("search.open")}
          onClick={onSearch}
        >
          <Icon name="search" />
          <span>{t("search.open")}</span>
          <kbd>{shortcutModifier}K</kbd>
        </button>
        {rightAvailable && (
          <button
            className="icon-button focus-ring"
            aria-controls="task-activity"
            aria-expanded={effectiveRightOpen}
            aria-label={t("app.toggle_activity")}
            title={t("app.toggle_activity")}
            onClick={toggleRight}
          >
            <Icon name="activity" />
          </button>
        )}
      </header>

      <div className="app-columns">
        <aside
          id="workspace-sidebar"
          className="workspace-sidebar"
          aria-hidden={!leftOpen}
          inert={!leftOpen}
        >
          {left}
        </aside>
        <section className="task-stage">{children}</section>
        {rightAvailable && (
          <aside
            id="task-activity"
            className="task-activity"
            aria-hidden={!effectiveRightOpen}
            inert={!effectiveRightOpen}
          >
            {activity}
          </aside>
        )}
      </div>

      {(leftOpen || effectiveRightOpen) && (
        <button
          className="panel-scrim"
          aria-label={t("app.dismiss_panels")}
          onClick={() => {
            if (window.innerWidth < 820) setLeftOpen(false);
            if (window.innerWidth <= 1100) setRightOpen(false);
          }}
        />
      )}
    </main>
  );
}
