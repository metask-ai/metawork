import { useEffect, useState, type ReactNode } from "react";

import { Icon } from "../components/ui/Icon.tsx";
import {
  WindowControls,
  type WindowControlAction,
} from "../components/ui/WindowControls.tsx";
import { WindowTitlebar } from "../components/ui/WindowTitlebar.tsx";
import { shouldDismissInspectorForEscape } from "../features/inspector/inspector-interaction.ts";
import { useI18n } from "../i18n/context.ts";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../platform/local-preferences.ts";
import {
  desktopPlatform,
  primaryShortcutModifier,
} from "../platform/keyboard.ts";
import type { WindowTitlebarClickCount } from "../platform/window-chrome.ts";

const leftPreference = "metawork.panel.workspaces";
function initialPanel(key: string, minimumWidth: number) {
  if (typeof window === "undefined") return true;
  const stored = readLocalPreference(key);
  return window.innerWidth >= minimumWidth && stored !== "closed";
}

export function AppShell({
  taskTitle,
  contextVisible,
  attentionNotice,
  onBeginWindowDrag,
  onToggleWindowSize,
  onOpenWindowMenu,
  windowMaximized,
  onWindowControl,
  onSearch,
  left,
  inspector,
  inspectorOpen,
  onDismissInspector,
  children,
}: {
  taskTitle: string;
  contextVisible: boolean;
  attentionNotice: string | null;
  onBeginWindowDrag: (clicks: WindowTitlebarClickCount) => void;
  onToggleWindowSize?: () => void;
  onOpenWindowMenu?: () => void;
  windowMaximized: boolean;
  onWindowControl: (action: WindowControlAction) => void;
  onSearch: () => void;
  left: ReactNode | null;
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
  const leftAvailable = left !== null;
  const effectiveLeftOpen = leftAvailable && leftOpen;
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
      data-platform={desktopPlatform()}
      data-left-open={effectiveLeftOpen}
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
      <WindowTitlebar
        className="workbench-commandbar"
        onBeginWindowDrag={onBeginWindowDrag}
        onToggleWindowSize={onToggleWindowSize}
        onOpenWindowMenu={onOpenWindowMenu}
      >
        {leftAvailable ? (
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
        ) : (
          <span className="commandbar-leading-spacer" aria-hidden="true" />
        )}
        <div className="commandbar-context" data-visible={contextVisible}>
          {contextVisible && (
            <span className="commandbar-task">{taskTitle}</span>
          )}
        </div>
        <div className="commandbar-alert-slot">
          <span
            className="sr-only"
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            {attentionNotice ?? ""}
          </span>
          {attentionNotice && (
            <details className="commandbar-alert">
              <summary aria-label={attentionNotice}>
                <Icon name="warning" />
                <span>{attentionNotice}</span>
              </summary>
              <p>{attentionNotice}</p>
            </details>
          )}
        </div>
        <button
          className="commandbar-search focus-ring"
          aria-label={t("search.open")}
          title={t("search.open")}
          onClick={onSearch}
        >
          <Icon name="search" />
          <span>{t("search.open")}</span>
          <kbd>{shortcutModifier}K</kbd>
        </button>
        <WindowControls
          maximized={windowMaximized}
          labels={{
            controls: t("window.controls"),
            minimize: t("window.minimize"),
            maximize: t("window.maximize"),
            restore: t("window.restore"),
            close: t("window.close"),
          }}
          onAction={onWindowControl}
        />
      </WindowTitlebar>

      <div className="app-columns">
        {leftAvailable && (
          <aside
            id="workspace-sidebar"
            className="workspace-sidebar"
            aria-hidden={!leftOpen}
            inert={!leftOpen}
          >
            {left}
          </aside>
        )}
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

      {effectiveLeftOpen && (
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
