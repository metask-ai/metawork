import { useEffect, useState, type ReactNode } from "react";

import { Icon } from "../components/ui/Icon.tsx";
import { shouldDismissInspectorForEscape } from "../features/inspector/inspector-interaction.ts";
import { useI18n } from "../i18n/context.ts";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../platform/local-preferences.ts";
import { primaryShortcutModifier } from "../platform/keyboard.ts";

const leftPreference = "metawork.panel.workspaces";
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
  inspector,
  inspectorOpen,
  onDismissInspector,
  children,
}: {
  taskTitle: string;
  workspaceLabel: string;
  status: string;
  onSearch: () => void;
  left: ReactNode;
  inspector: ReactNode | null;
  inspectorOpen: boolean;
  onDismissInspector: (restoreFocus?: boolean) => void;
  children: ReactNode;
}) {
  const { t } = useI18n();
  const shortcutModifier = primaryShortcutModifier();
  const [leftOpen, setLeftOpen] = useState(() =>
    initialPanel(leftPreference, 820),
  );
  const inspectorAvailable = inspector !== null;
  const effectiveInspectorOpen = inspectorAvailable && inspectorOpen;

  useEffect(() => {
    const narrow = window.matchMedia("(max-width: 819px)");
    const closeForViewport = () => {
      if (narrow.matches) setLeftOpen(false);
    };
    narrow.addEventListener("change", closeForViewport);
    return () => {
      narrow.removeEventListener("change", closeForViewport);
    };
  }, []);

  useEffect(() => {
    if (effectiveInspectorOpen && window.innerWidth < 820) setLeftOpen(false);
  }, [effectiveInspectorOpen]);

  function toggleLeft() {
    const next = !leftOpen;
    if (next && window.innerWidth < 820) onDismissInspector(false);
    writeLocalPreference(leftPreference, next ? "open" : "closed");
    setLeftOpen(next);
  }

  return (
    <main
      className="app-window"
      data-left-open={leftOpen}
      data-inspector-open={effectiveInspectorOpen}
      onKeyDown={(event) => {
        const target = event.target as HTMLElement;
        if (
          target.closest('[role="dialog"], [role="menu"], [role="alertdialog"]')
        )
          return;
        if (
          !shouldDismissInspectorForEscape(
            effectiveInspectorOpen,
            event.key,
            event.defaultPrevented,
          )
        )
          return;
        event.preventDefault();
        onDismissInspector();
      }}
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
        {inspectorAvailable && (
          <aside
            id="task-inspector"
            className="task-inspector"
            aria-labelledby="task-inspector-title"
            aria-hidden={!effectiveInspectorOpen}
            inert={!effectiveInspectorOpen}
          >
            {inspector}
          </aside>
        )}
      </div>

      {leftOpen && (
        <button
          className="panel-scrim"
          aria-label={t("app.dismiss_panels")}
          onClick={() => {
            if (window.innerWidth < 820) setLeftOpen(false);
          }}
        />
      )}
    </main>
  );
}
