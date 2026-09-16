import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type Ref,
} from "react";

import { Icon } from "../components/ui/Icon.tsx";
import { ResizableSeparator } from "../components/ui/ResizableSeparator.tsx";
import { WindowControls } from "../components/ui/WindowControls.tsx";
import { WindowTitlebar } from "../components/ui/WindowTitlebar.tsx";
import { shouldDismissSidePanelForEscape } from "./side-panel-interaction.ts";
import { useI18n } from "../i18n/context.ts";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../platform/local-preferences.ts";

const leftPreference = "metawork.panel.workspaces";
const leftWidthPreference = "metawork.panel.workspaces.width";
const defaultLeftWidth = 320;
const minimumLeftWidth = 240;
const maximumLeftWidth = 480;
const leftWidthStep = 16;
const rightWidthPreference = "metawork.panel.task.width";
const defaultRightWidth = 400;
const minimumRightWidth = 320;
const maximumRightWidth = 640;
const minimumTaskStageWidth = 480;
const rightWidthStep = 16;

export function shouldDockTaskPanel(
  viewportWidth: number,
  leftWidth: number,
  rightWidth: number,
) {
  return viewportWidth - leftWidth - rightWidth >= minimumTaskStageWidth;
}

export function isTaskStageExposed({
  viewportWidth,
  leftOpen,
  rightPanelOpen,
  rightPanelDocked,
  overlayOpen,
}: {
  viewportWidth: number;
  leftOpen: boolean;
  rightPanelOpen: boolean;
  rightPanelDocked: boolean;
  overlayOpen: boolean;
}) {
  return (
    !overlayOpen &&
    !(leftOpen && viewportWidth < 820) &&
    !(rightPanelOpen && !rightPanelDocked)
  );
}

function clampLeftWidth(value: number) {
  return Math.min(maximumLeftWidth, Math.max(minimumLeftWidth, value));
}

function initialLeftWidth() {
  const stored = readLocalPreference(leftWidthPreference);
  if (stored === null) return defaultLeftWidth;
  const parsed = Number(stored);
  return Number.isFinite(parsed) ? clampLeftWidth(parsed) : defaultLeftWidth;
}

function clampRightWidth(value: number) {
  return Math.min(maximumRightWidth, Math.max(minimumRightWidth, value));
}

function initialRightWidth() {
  const stored = readLocalPreference(rightWidthPreference);
  if (stored === null) return defaultRightWidth;
  const parsed = Number(stored);
  return Number.isFinite(parsed) ? clampRightWidth(parsed) : defaultRightWidth;
}

function initialPanel(key: string, minimumWidth: number) {
  if (typeof window === "undefined") return true;
  const stored = readLocalPreference(key);
  return window.innerWidth >= minimumWidth && stored !== "closed";
}

export function AppShell({
  taskTitle,
  contextVisible,
  contextContent,
  headerActions,
  attentionNotice,
  onSearch,
  left,
  rightPanel,
  rightPanelOpen,
  onDismissRightPanel,
  onToggleRightPanel,
  rightPanelToggleRef,
  onTaskStageExposureChange,
  overlay,
  children,
}: {
  taskTitle: string;
  contextVisible: boolean;
  contextContent?: ReactNode;
  headerActions?: ReactNode;
  attentionNotice: string | null;
  onSearch: () => void;
  left: ReactNode | null;
  rightPanel: ReactNode | null;
  rightPanelOpen: boolean;
  onDismissRightPanel: (restoreFocus?: boolean) => void;
  onToggleRightPanel: (opener: HTMLButtonElement) => void;
  rightPanelToggleRef?: Ref<HTMLButtonElement>;
  onTaskStageExposureChange?: (exposed: boolean) => void;
  overlay?: ReactNode;
  children: ReactNode;
}) {
  const { t } = useI18n();
  const [leftOpen, setLeftOpen] = useState(() =>
    initialPanel(leftPreference, 820),
  );
  const [leftWidth, setLeftWidth] = useState(initialLeftWidth);
  const [rightWidth, setRightWidth] = useState(initialRightWidth);
  const [resizingLeft, setResizingLeft] = useState(false);
  const [resizingRight, setResizingRight] = useState(false);
  const [viewportWidth, setViewportWidth] = useState(() =>
    typeof window === "undefined" ? 1440 : window.innerWidth,
  );
  const leftAvailable = left !== null;
  const effectiveLeftOpen = leftAvailable && leftOpen;
  const rightPanelAvailable = rightPanel !== null;
  const effectiveRightPanelOpen = rightPanelOpen;
  const rightResizeMaximum = Math.max(
    minimumRightWidth,
    Math.min(maximumRightWidth, viewportWidth - 44),
  );
  const renderedRightWidth = Math.min(rightWidth, rightResizeMaximum);
  const rightPanelDocked =
    effectiveRightPanelOpen &&
    shouldDockTaskPanel(
      viewportWidth,
      effectiveLeftOpen ? leftWidth : 0,
      rightWidth,
    );
  const taskStageExposed = isTaskStageExposed({
    viewportWidth,
    leftOpen: effectiveLeftOpen,
    rightPanelOpen: effectiveRightPanelOpen,
    rightPanelDocked,
    overlayOpen: Boolean(overlay),
  });
  const attentionDetails = useRef<HTMLDetailsElement>(null);

  useLayoutEffect(() => {
    onTaskStageExposureChange?.(taskStageExposed);
  }, [onTaskStageExposureChange, taskStageExposed]);

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
    const observeViewport = () => setViewportWidth(window.innerWidth);
    window.addEventListener("resize", observeViewport);
    return () => window.removeEventListener("resize", observeViewport);
  }, []);

  useEffect(() => {
    if (effectiveRightPanelOpen && window.innerWidth < 820) setLeftOpen(false);
  }, [effectiveRightPanelOpen]);

  useEffect(() => {
    if (effectiveRightPanelOpen || !resizingRight) return;
    writeLocalPreference(rightWidthPreference, String(rightWidth));
    setResizingRight(false);
  }, [effectiveRightPanelOpen, resizingRight, rightWidth]);

  useEffect(() => {
    if (overlay && attentionDetails.current)
      attentionDetails.current.open = false;
  }, [overlay]);

  function toggleLeft() {
    const next = !leftOpen;
    if (next && window.innerWidth < 820) onDismissRightPanel(false);
    writeLocalPreference(leftPreference, next ? "open" : "closed");
    setLeftOpen(next);
  }

  return (
    <main
      className="app-window"
      data-left-open={effectiveLeftOpen}
      data-right-panel-open={effectiveRightPanelOpen}
      data-right-panel-docked={rightPanelDocked}
      data-resizing-left={resizingLeft}
      data-resizing-right={resizingRight}
      style={
        {
          "--left-column-width": `${leftWidth}px`,
          "--right-column-width": `${rightWidth}px`,
          "--right-panel-rendered-width": `${renderedRightWidth}px`,
        } as CSSProperties
      }
      onKeyDown={(event) => {
        const target = event.target as HTMLElement;
        if (
          target.closest('[role="dialog"], [role="menu"], [role="alertdialog"]')
        )
          return;
        if (
          !shouldDismissSidePanelForEscape(
            effectiveRightPanelOpen,
            event.key,
            event.defaultPrevented,
          )
        )
          return;
        event.preventDefault();
        onDismissRightPanel();
      }}
    >
      <WindowTitlebar className="workbench-commandbar">
        <div
          className="commandbar-leading-actions"
          inert={overlay ? true : undefined}
        >
          {leftAvailable && (
            <button
              className="icon-button focus-ring"
              aria-controls="workspace-sidebar"
              aria-expanded={leftOpen}
              aria-label={t("app.toggle_sidebar")}
              title={t("app.toggle_sidebar")}
              onClick={toggleLeft}
            >
              <Icon name="sidebar" />
            </button>
          )}
          <button
            className="icon-button focus-ring"
            aria-label={t("search.open")}
            onClick={onSearch}
          >
            <Icon name="search" />
          </button>
        </div>
        <div
          className="commandbar-context"
          data-visible={contextVisible}
          inert={overlay ? true : undefined}
        >
          {contextVisible &&
            (contextContent ?? (
              <span className="commandbar-task">{taskTitle}</span>
            ))}
        </div>
        <div
          className="commandbar-alert-slot"
          inert={overlay ? true : undefined}
        >
          {headerActions}
          <button
            type="button"
            ref={rightPanelToggleRef}
            className="icon-button focus-ring"
            aria-controls="task-panel"
            aria-expanded={effectiveRightPanelOpen}
            aria-label={t(
              effectiveRightPanelOpen ? "task_panel.close" : "task_panel.open",
            )}
            title={t(
              effectiveRightPanelOpen ? "task_panel.close" : "task_panel.open",
            )}
            onClick={(event) => onToggleRightPanel(event.currentTarget)}
          >
            <Icon name="sidebar-right" />
          </button>
          <span
            className="sr-only"
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            {attentionNotice ?? ""}
          </span>
          {attentionNotice && (
            <details ref={attentionDetails} className="commandbar-alert">
              <summary aria-label={attentionNotice}>
                <Icon name="warning" />
                <span>{attentionNotice}</span>
              </summary>
              <p>{attentionNotice}</p>
            </details>
          )}
        </div>
        <WindowControls
          labels={{
            controls: t("window.controls"),
            minimize: t("window.minimize"),
            maximize: t("window.maximize"),
            restore: t("window.restore"),
            close: t("window.close"),
          }}
        />
      </WindowTitlebar>

      <div className="app-columns" inert={overlay ? true : undefined}>
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
        {effectiveLeftOpen && (
          <ResizableSeparator
            className="workspace-resize-handle"
            label={t("app.resize_sidebar")}
            value={leftWidth}
            minimum={minimumLeftWidth}
            maximum={maximumLeftWidth}
            step={leftWidthStep}
            onChange={setLeftWidth}
            onCommit={(width) =>
              writeLocalPreference(leftWidthPreference, String(width))
            }
            onResizeStart={() => setResizingLeft(true)}
            onResizeEnd={() => setResizingLeft(false)}
          />
        )}
        <section className="task-stage">{children}</section>
        {(effectiveRightPanelOpen || resizingRight) && (
          <ResizableSeparator
            className="task-panel-resize-handle"
            label={t("app.resize_task_panel")}
            value={renderedRightWidth}
            minimum={minimumRightWidth}
            maximum={rightResizeMaximum}
            step={rightWidthStep}
            reverse
            onChange={setRightWidth}
            onCommit={(width) =>
              writeLocalPreference(rightWidthPreference, String(width))
            }
            onResizeStart={() => setResizingRight(true)}
            onResizeEnd={() => setResizingRight(false)}
          />
        )}
        {(rightPanelAvailable || effectiveRightPanelOpen) && (
          <aside
            id="task-panel"
            className="task-panel"
            aria-labelledby={
              effectiveRightPanelOpen ? "task-panel-title" : undefined
            }
            aria-hidden={!effectiveRightPanelOpen}
            inert={!effectiveRightPanelOpen}
          >
            {effectiveRightPanelOpen ? rightPanel : null}
          </aside>
        )}
      </div>

      {overlay && <div className="app-overlay-layer">{overlay}</div>}

      {effectiveLeftOpen && !overlay && (
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
