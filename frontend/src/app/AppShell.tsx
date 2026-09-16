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
const rightSharePreference = "metawork.panel.task.share";
const defaultRightShare = 1 / 3;
const defaultRightOverlayWidth = 400;
const minimumRightWidth = 360;
const minimumTaskStageWidth = 360;
const minimumDockedWorkAreaWidth = minimumTaskStageWidth + minimumRightWidth;
const rightWidthStep = 16;

function normalizeRightShare(value: number) {
  return Number.isFinite(value) && value > 0 && value < 1
    ? value
    : defaultRightShare;
}

export function resolveWorkbenchColumns({
  viewportWidth,
  leftOpen,
  leftWidth,
  rightOpen,
  rightShare,
}: {
  viewportWidth: number;
  leftOpen: boolean;
  leftWidth: number;
  rightOpen: boolean;
  rightShare: number;
}) {
  const dockedLeftWidth =
    leftOpen && viewportWidth >= 820 ? clampLeftWidth(leftWidth) : 0;
  const availableWidth = Math.max(0, viewportWidth - dockedLeftWidth);
  const normalizedRightShare = normalizeRightShare(rightShare);
  const rightMinimum = minimumRightWidth;
  const rightMaximum = Math.max(
    minimumRightWidth,
    availableWidth - minimumTaskStageWidth,
  );
  const docked = rightOpen && availableWidth >= minimumDockedWorkAreaWidth;

  if (!docked) {
    return {
      availableWidth,
      docked,
      middleWidth: availableWidth,
      rightWidth: rightOpen
        ? Math.min(defaultRightOverlayWidth, Math.max(0, viewportWidth - 44))
        : 0,
      rightMinimum,
      rightMaximum,
      rightShare: normalizedRightShare,
    };
  }

  const rightWidth = Math.ceil(
    Math.min(
      rightMaximum,
      Math.max(rightMinimum, availableWidth * normalizedRightShare),
    ),
  );
  return {
    availableWidth,
    docked,
    middleWidth: availableWidth - rightWidth,
    rightWidth,
    rightMinimum: Math.ceil(rightMinimum),
    rightMaximum: Math.ceil(rightMaximum),
    rightShare: normalizedRightShare,
  };
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

function initialRightShare() {
  const stored = readLocalPreference(rightSharePreference);
  if (stored === null) return defaultRightShare;
  const parsed = Number(stored);
  return normalizeRightShare(parsed);
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
  const [rightShare, setRightShare] = useState(initialRightShare);
  const [resizingLeft, setResizingLeft] = useState(false);
  const [resizingRight, setResizingRight] = useState(false);
  const [viewportWidth, setViewportWidth] = useState(() =>
    typeof window === "undefined" ? 1440 : window.innerWidth,
  );
  const leftAvailable = left !== null;
  const effectiveLeftOpen = leftAvailable && leftOpen;
  const rightPanelAvailable = rightPanel !== null;
  const effectiveRightPanelOpen = rightPanelOpen;
  const columns = resolveWorkbenchColumns({
    viewportWidth,
    leftOpen: effectiveLeftOpen,
    leftWidth,
    rightOpen: effectiveRightPanelOpen,
    rightShare,
  });
  const rightPanelDocked = columns.docked;
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
    if (!resizingRight || (effectiveRightPanelOpen && rightPanelDocked)) return;
    writeLocalPreference(rightSharePreference, String(rightShare));
    setResizingRight(false);
  }, [effectiveRightPanelOpen, resizingRight, rightPanelDocked, rightShare]);

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

  function shareForRightWidth(width: number) {
    if (columns.availableWidth <= 0) return defaultRightShare;
    return normalizeRightShare(width / columns.availableWidth);
  }

  function changeRightWidth(width: number) {
    setRightShare(shareForRightWidth(width));
  }

  function commitRightWidth(width: number) {
    writeLocalPreference(
      rightSharePreference,
      String(shareForRightWidth(width)),
    );
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
          "--task-stage-share": 1 - columns.rightShare,
          "--task-panel-share": columns.rightShare,
          "--right-panel-overlay-width": `${columns.rightWidth}px`,
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
        {rightPanelDocked && (
          <ResizableSeparator
            className="task-panel-resize-handle"
            label={t("app.resize_task_panel")}
            value={columns.rightWidth}
            minimum={columns.rightMinimum}
            maximum={columns.rightMaximum}
            step={rightWidthStep}
            reverse
            onChange={changeRightWidth}
            onCommit={commitRightWidth}
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
