import { commands } from "./commands.ts";
import {
  assertDisconnected,
  assertWindowChromeHandled,
  decodeWindowChromeEnvironment,
  type WindowChromeEnvironment,
} from "./decode-contracts.ts";

const controlSelector = "[data-metawork-window-control]";
const exclusionSelector =
  "button, input, select, textarea, label, details, summary, a, [contenteditable]:not([contenteditable='false']), [role='button'], [role='link'], [role='textbox'], [tabindex], [inert], [data-metawork-window-drag-exclude]";
const controlActions = new Set(["minimize", "toggle_maximize", "close"]);
let bindTitlebar: ((element: HTMLElement) => () => void) | null = null;

// React registers only its actual DOM node; this module owns input and transport.
export function bindWindowTitlebar(element: HTMLElement) {
  return bindTitlebar?.(element) ?? (() => undefined);
}

export function installWindowChromeBridge() {
  const bridge = window.zero;
  if (!bridge) return () => undefined;
  let disposed = false;
  let generation: string | null = null;
  let environment: WindowChromeEnvironment | null = null;
  let stateEpoch = 0;
  let refreshInFlight = false;
  let refreshDirty = false;
  let controlInFlight = false;
  const disabledControls = new Set<HTMLButtonElement>();
  const titlebars = new Map<HTMLElement, () => void>();

  function applyEnvironment(value: WindowChromeEnvironment) {
    environment = value;
    const root = document.documentElement;
    root.dataset.metaworkWindowChrome = "ready";
    root.dataset.metaworkRendererWindowControls = String(
      value.rendererControls,
    );
    root.dataset.metaworkWindowMaximized = String(value.maximized);
    root.style.setProperty(
      "--metawork-window-chrome-top",
      value.insets.top + "px",
    );
    root.style.setProperty(
      "--metawork-window-chrome-leading",
      value.insets.left + "px",
    );
    root.style.setProperty(
      "--metawork-window-chrome-trailing",
      value.insets.right + "px",
    );
    root.style.setProperty(
      "--metawork-window-chrome-buttons-x",
      value.buttons.x + "px",
    );
    root.style.setProperty(
      "--metawork-window-chrome-buttons-width",
      value.buttons.width + "px",
    );
  }
  function clearEnvironment() {
    environment = null;
    const root = document.documentElement;
    delete root.dataset.metaworkWindowChrome;
    delete root.dataset.metaworkRendererWindowControls;
    delete root.dataset.metaworkWindowMaximized;
    for (const name of [
      "--metawork-window-chrome-top",
      "--metawork-window-chrome-leading",
      "--metawork-window-chrome-trailing",
      "--metawork-window-chrome-buttons-x",
      "--metawork-window-chrome-buttons-width",
    ])
      root.style.removeProperty(name);
  }
  async function refresh() {
    if (disposed || !generation || refreshInFlight || !refreshDirty) return;
    refreshDirty = false;
    refreshInFlight = true;
    const requestGeneration = generation;
    const requestEpoch = stateEpoch;
    try {
      const value = decodeWindowChromeEnvironment(
        await bridge.invoke(commands.windowChromeRefresh, {
          generation: requestGeneration,
        }),
      );
      if (
        !disposed &&
        generation === requestGeneration &&
        value.generation === requestGeneration &&
        stateEpoch === requestEpoch
      )
        applyEnvironment(value);
    } catch {
      // Keep the last confirmed controls and session. A later event can refresh.
    } finally {
      refreshInFlight = false;
      if (refreshDirty) void refresh();
    }
  }
  function scheduleRefresh() {
    if (disposed) return;
    stateEpoch++;
    refreshDirty = true;
    void refresh();
  }
  async function disconnect(expectedGeneration: string) {
    try {
      assertDisconnected(
        await bridge.invoke(commands.windowChromeDisconnect, {
          generation: expectedGeneration,
        }),
        expectedGeneration,
      );
    } catch {
      // A replacement document may already have revoked this exact generation.
    }
  }
  function isDragTarget(event: Event, titlebar: HTMLElement) {
    const path = event.composedPath();
    if (!path.includes(titlebar)) return false;
    for (const entry of path) {
      if (!(entry instanceof Element)) continue;
      if (entry.matches(exclusionSelector)) return false;
    }
    return true;
  }
  async function submitGesture(
    action: "start_drag" | "toggle_maximize",
    event: MouseEvent,
  ) {
    if (disposed || !generation) return;
    const requestGeneration = generation;
    stateEpoch++;
    try {
      assertWindowChromeHandled(
        await bridge.invoke(commands.windowChromeGesture, {
          generation: requestGeneration,
          action,
          x: event.clientX,
          y: event.clientY,
        }),
        requestGeneration,
      );
    } catch {
      // Never replay a gesture or reconnect on a rejected action.
    } finally {
      if (!disposed && generation === requestGeneration) scheduleRefresh();
    }
  }
  function bind(element: HTMLElement) {
    titlebars.get(element)?.();
    if (disposed) return () => undefined;
    function onMouseDown(event: MouseEvent) {
      if (
        disposed ||
        !generation ||
        environment?.gestureMode !== "browser_mouse" ||
        !event.isTrusted ||
        event.button !== 0 ||
        !isDragTarget(event, element) ||
        (event.detail !== 1 && event.detail !== 2)
      )
        return;
      // Tauri 2.11.5 drag.js Windows branch: only clicks 1 and 2 select actions.
      // Binding is local and the entire noninteractive titlebar is draggable.
      event.preventDefault();
      event.stopImmediatePropagation();
      void submitGesture(
        event.detail === 2 ? "toggle_maximize" : "start_drag",
        event,
      );
    }
    function onPointerDown(event: PointerEvent) {
      if (
        disposed ||
        !generation ||
        environment?.gestureMode !== "native_press" ||
        !event.isTrusted ||
        event.button !== 0 ||
        !event.isPrimary ||
        !isDragTarget(event, element)
      )
        return;
      void submitGesture("start_drag", event);
    }
    function onClick(event: MouseEvent) {
      if (event.composedPath().includes(element)) void onControlClick(event);
    }
    element.addEventListener("mousedown", onMouseDown);
    element.addEventListener("pointerdown", onPointerDown);
    element.addEventListener("click", onClick);
    let unbound = false;
    function unbind() {
      if (unbound) return;
      unbound = true;
      element.removeEventListener("mousedown", onMouseDown);
      element.removeEventListener("pointerdown", onPointerDown);
      element.removeEventListener("click", onClick);
      if (titlebars.get(element) === unbind) titlebars.delete(element);
      for (const button of disabledControls) {
        if (element.contains(button)) {
          button.disabled = false;
          disabledControls.delete(button);
        }
      }
    }
    titlebars.set(element, unbind);
    return unbind;
  }
  bindTitlebar = bind;
  function releaseControls() {
    for (const control of disabledControls) control.disabled = false;
    disabledControls.clear();
    controlInFlight = false;
  }
  async function onControlClick(event: MouseEvent) {
    const button = event
      .composedPath()
      .find(
        (entry): entry is HTMLButtonElement =>
          entry instanceof Element && entry.matches("button" + controlSelector),
      );
    const action = button?.dataset.metaworkWindowControl;
    if (
      disposed ||
      !button ||
      button.disabled ||
      button.closest("[inert]") ||
      !action ||
      !controlActions.has(action) ||
      !environment?.rendererControls ||
      !generation ||
      controlInFlight
    )
      return;
    event.preventDefault();
    const requestGeneration = generation;
    controlInFlight = true;
    stateEpoch++;
    for (const titlebar of titlebars.keys()) {
      for (const control of titlebar.querySelectorAll<HTMLButtonElement>(
        "button" + controlSelector,
      )) {
        if (!control.disabled) {
          disabledControls.add(control);
          control.disabled = true;
        }
      }
    }
    try {
      assertWindowChromeHandled(
        await bridge.invoke(commands.windowChromeControl, {
          generation: requestGeneration,
          action,
        }),
        requestGeneration,
      );
    } catch {
      // Preserve the current document session; never retry a window action.
    } finally {
      if (!disposed && generation === requestGeneration) {
        releaseControls();
        scheduleRefresh();
      }
    }
  }
  void bridge
    .invoke(commands.windowChromeConnect, {})
    .then(decodeWindowChromeEnvironment)
    .then((value) => {
      if (disposed) {
        void disconnect(value.generation);
        return;
      }
      generation = value.generation;
      applyEnvironment(value);
      // Observe native changes that occurred while connect was pending.
      scheduleRefresh();
    })
    .catch(() => {
      if (!disposed) clearEnvironment();
    });
  const unsubscribeResize = bridge.on("resize", scheduleRefresh);
  window.addEventListener("pagehide", dispose, { once: true });
  window.addEventListener("focus", scheduleRefresh);
  function dispose() {
    if (disposed) return;
    disposed = true;
    stateEpoch++;
    refreshDirty = false;
    unsubscribeResize();
    window.removeEventListener("pagehide", dispose);
    window.removeEventListener("focus", scheduleRefresh);
    if (bindTitlebar === bind) bindTitlebar = null;
    for (const unbind of titlebars.values()) unbind();
    releaseControls();
    const detachedGeneration = generation;
    generation = null;
    clearEnvironment();
    if (detachedGeneration) void disconnect(detachedGeneration);
  }
  return dispose;
}
