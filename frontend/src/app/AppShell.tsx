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
import { bindWindowTitlebar } from "../bridge/window-chrome.ts";
import { shouldDismissSidePanelForEscape } from "./side-panel-interaction.ts";
import { useI18n } from "../i18n/context.ts";
import { isInputMethodKey } from "../platform/keyboard.ts";
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
  containerWidth,
  leftOpen,
  leftWidth,
  rightOpen,
  rightShare,
}: {
  containerWidth: number;
  leftOpen: boolean;
  leftWidth: number;
  rightOpen: boolean;
  rightShare: number;
}) {
  const resolvedContainerWidth =
    Number.isFinite(containerWidth) && containerWidth > 0
      ? Math.floor(containerWidth)
      : 0;
  const dockedLeftWidth =
    leftOpen && resolvedContainerWidth >= 820 ? clampLeftWidth(leftWidth) : 0;
  const availableWidth = Math.max(0, resolvedContainerWidth - dockedLeftWidth);
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
        ? Math.min(
            defaultRightOverlayWidth,
            Math.max(0, resolvedContainerWidth - 44),
          )
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

// A minimized or hidden window can report an empty viewport. That is not a
// narrow layout, so it must neither collapse panels nor replace the width.
function hasViewport() {
  return window.innerWidth > 0;
}

export function AppShell({
  taskTitle,
  contextVisible,
  headerActions,
  attentionNotice,
  attentionContent,
  attentionBusy = false,
  attentionAnnouncement,
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
  headerActions?: ReactNode;
  attentionNotice: string | null;
  attentionContent?: ReactNode;
  attentionBusy?: boolean;
  attentionAnnouncement?: { key: number; text: string } | null;
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
  const [workbenchWidth, setWorkbenchWidth] = useState(() =>
    typeof window === "undefined" ? 1440 : window.innerWidth,
  );
  const workbenchElement = useRef<HTMLElement>(null);
  const leftAvailable = left !== null;
  const effectiveLeftOpen = leftAvailable && leftOpen;
  const effectiveRightPanelOpen = rightPanelOpen;
  const columns = resolveWorkbenchColumns({
    containerWidth: workbenchWidth,
    leftOpen: effectiveLeftOpen,
    leftWidth,
    rightOpen: effectiveRightPanelOpen,
    rightShare,
  });
  const rightPanelPlacement = effectiveRightPanelOpen
    ? columns
    : resolveWorkbenchColumns({
        containerWidth: workbenchWidth,
        leftOpen: effectiveLeftOpen,
        leftWidth,
        rightOpen: true,
        rightShare,
      });
  const rightPanelDocked = rightPanelPlacement.docked;
  const taskStageExposed = isTaskStageExposed({
    viewportWidth: workbenchWidth,
    leftOpen: effectiveLeftOpen,
    rightPanelOpen: effectiveRightPanelOpen,
    rightPanelDocked,
    overlayOpen: Boolean(overlay),
  });
  const attentionDetails = useRef<HTMLDetailsElement>(null);
  const compositionTarget = useRef<EventTarget | null>(null);
  const attentionHadFocus = useRef(false);
  const attentionFocusedElement = useRef<HTMLElement | null>(null);
  const searchButton = useRef<HTMLButtonElement>(null);

  useLayoutEffect(() => {
    const focusedControlWasRemoved =
      attentionFocusedElement.current !== null &&
      !attentionFocusedElement.current.isConnected &&
      document.activeElement === document.body;
    if (
      (!attentionNotice && attentionHadFocus.current) ||
      focusedControlWasRemoved
    ) {
      attentionHadFocus.current = false;
      attentionFocusedElement.current = null;
      if (attentionNotice)
        attentionDetails.current?.querySelector("summary")?.focus();
      else searchButton.current?.focus();
    }
  }, [attentionNotice, attentionContent]);

  useLayoutEffect(() => {
    onTaskStageExposureChange?.(taskStageExposed);
  }, [onTaskStageExposureChange, taskStageExposed]);

  useEffect(() => {
    const narrow = window.matchMedia("(max-width: 819px)");
    const closeForViewport = () => {
      if (narrow.matches && hasViewport()) setLeftOpen(false);
    };
    narrow.addEventListener("change", closeForViewport);
    return () => {
      narrow.removeEventListener("change", closeForViewport);
    };
  }, []);

  useLayoutEffect(() => {
    const element = workbenchElement.current;
    if (!element) return;
    const measure = (observedWidth?: number) => {
      if (!hasViewport()) return;
      const measuredWidth =
        observedWidth && observedWidth > 0
          ? observedWidth
          : element.getBoundingClientRect().width;
      const nextWidth = measuredWidth > 0 ? measuredWidth : window.innerWidth;
      setWorkbenchWidth((current) =>
        current === nextWidth ? current : nextWidth,
      );
    };
    const observer =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver((entries) =>
            measure(
              entries.find((entry) => entry.target === element)?.contentRect
                .width,
            ),
          );
    observer?.observe(element);
    const observeWindowFallback = () => measure();
    window.addEventListener("resize", observeWindowFallback);
    measure();
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", observeWindowFallback);
    };
  }, []);

  useEffect(() => {
    if (effectiveRightPanelOpen && workbenchWidth < 820) setLeftOpen(false);
  }, [effectiveRightPanelOpen, workbenchWidth]);

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
    if (next && workbenchWidth < 820) onDismissRightPanel(false);
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
      ref={workbenchElement}
      className="app-window"
      data-left-open={effectiveLeftOpen}
      data-right-panel-open={effectiveRightPanelOpen}
      data-right-panel-docked={rightPanelDocked}
      data-resizing-left={resizingLeft}
      data-resizing-right={resizingRight}
      style={
        {
          "--left-column-width": `${leftWidth}px`,
          "--right-panel-width": `${rightPanelPlacement.rightWidth}px`,
        } as CSSProperties
      }
      onCompositionStartCapture={(event) => {
        compositionTarget.current = event.target;
      }}
      onCompositionEndCapture={(event) => {
        if (compositionTarget.current === event.target)
          compositionTarget.current = null;
      }}
      onFocusCapture={(event) => {
        if (compositionTarget.current !== event.target)
          compositionTarget.current = null;
      }}
      onBlurCapture={(event) => {
        if (compositionTarget.current === event.target)
          compositionTarget.current = null;
      }}
      onKeyDownCapture={(event) => {
        if (
          event.defaultPrevented ||
          isInputMethodKey(
            event.nativeEvent,
            compositionTarget.current !== null,
          )
        )
          return;
        if (event.key === "Escape" && attentionDetails.current?.open) {
          event.preventDefault();
          attentionDetails.current.open = false;
          attentionDetails.current.querySelector("summary")?.focus();
        }
      }}
      onKeyDown={(event) => {
        if (
          isInputMethodKey(
            event.nativeEvent,
            compositionTarget.current !== null,
          )
        )
          return;
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
      <WindowTitlebar ref={bindWindowTitlebar} className="workbench-commandbar">
        <div
          className="commandbar-leading-actions"
          data-native-window-drag-exclude=""
        >
          <div
            className="commandbar-inert-content"
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
              ref={searchButton}
              aria-label={t("search.open")}
              onClick={onSearch}
            >
              <Icon name="search" />
            </button>
          </div>
        </div>
        <div
          className="commandbar-context"
          data-visible={contextVisible}
          data-native-window-drag-exclude={overlay ? "" : undefined}
        >
          <div
            className="commandbar-inert-content"
            inert={overlay ? true : undefined}
          >
            {contextVisible && (
              <span className="commandbar-task">{taskTitle}</span>
            )}
          </div>
        </div>
        <div
          className="commandbar-alert-slot"
          data-native-window-drag-exclude=""
        >
          <span
            className="sr-only"
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            <span key={attentionAnnouncement?.key ?? 0}>
              {attentionAnnouncement === undefined
                ? (attentionNotice ?? "")
                : (attentionAnnouncement?.text ?? "")}
            </span>
          </span>
          <div
            className="commandbar-inert-content"
            inert={overlay ? true : undefined}
          >
            <div className="commandbar-context-actions">{headerActions}</div>
            <button
              type="button"
              ref={rightPanelToggleRef}
              className="icon-button commandbar-task-panel-toggle focus-ring"
              aria-controls="task-panel"
              aria-expanded={effectiveRightPanelOpen}
              aria-label={t(
                effectiveRightPanelOpen ? "task_panel.hide" : "task_panel.open",
              )}
              title={t(
                effectiveRightPanelOpen ? "task_panel.hide" : "task_panel.open",
              )}
              onClick={(event) => onToggleRightPanel(event.currentTarget)}
            >
              <Icon name="sidebar-right" />
            </button>

            {attentionNotice && (
              <details
                ref={attentionDetails}
                className="commandbar-alert"
                data-recovering={attentionBusy}
                onFocusCapture={(event) => {
                  attentionHadFocus.current = true;
                  attentionFocusedElement.current = event.target as HTMLElement;
                }}
                onBlurCapture={(event) => {
                  if (
                    !event.currentTarget.contains(
                      event.relatedTarget as Node | null,
                    )
                  ) {
                    attentionHadFocus.current = false;
                    if (
                      event.relatedTarget !== null ||
                      attentionFocusedElement.current?.isConnected
                    )
                      attentionFocusedElement.current = null;
                  }
                }}
              >
                <summary aria-label={attentionNotice}>
                  {attentionBusy ? (
                    <i
                      className="connection-recovery-mark"
                      aria-hidden="true"
                    />
                  ) : (
                    <Icon name="warning" />
                  )}
                  <span>{attentionNotice}</span>
                </summary>
                <div className="commandbar-alert-content">
                  {attentionContent ?? <p>{attentionNotice}</p>}
                </div>
              </details>
            )}
          </div>
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
        {effectiveRightPanelOpen && rightPanelDocked && (
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
      </div>

      {overlay && <div className="app-overlay-layer">{overlay}</div>}

      {effectiveLeftOpen && !overlay && (
        <button
          className="panel-scrim"
          aria-label={t("app.dismiss_panels")}
          onClick={() => {
            if (workbenchWidth < 820) setLeftOpen(false);
          }}
        />
      )}
    </main>
  );
}
