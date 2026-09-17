import { commands } from "./commands.ts";
import {
  assertDisconnected,
  assertWindowChromeHandled,
  decodeWindowChromeEnvironment,
  type WindowChromeEnvironment,
} from "./decode-contracts.ts";

const candidateSelector = "[data-metawork-window-drag]";
const controlSelector = "[data-metawork-window-control]";
const exclusionSelector =
  "button, input, select, textarea, label, details, a, [contenteditable]:not([contenteditable='false']), [role='button'], [role='link'], [role='textbox'], [tabindex], [inert], [data-metawork-window-drag-exclude]";
const controlActions = new Set(["minimize", "toggle_maximize", "close"]);

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
  function isDragTarget(event: PointerEvent) {
    let candidate = false;
    for (const entry of event.composedPath()) {
      if (!(entry instanceof Element)) continue;
      if (entry.matches(exclusionSelector)) return false;
      if (entry.matches(candidateSelector)) candidate = true;
    }
    return candidate;
  }
  async function submitPointer(
    pointer: { phase: "down"; x: number; y: number } | { phase: "reset" },
  ) {
    if (disposed || !generation || !environment?.livePointerDrag) return;
    const requestGeneration = generation;
    if (pointer.phase === "down") stateEpoch++;
    try {
      assertWindowChromeHandled(
        await bridge.invoke(commands.windowChromePointer, {
          generation: requestGeneration,
          ...pointer,
        }),
        requestGeneration,
      );
    } catch {
      // Never replay a pointer gesture or reconnect on a rejected action.
    } finally {
      if (
        !disposed &&
        generation === requestGeneration &&
        pointer.phase === "down"
      )
        scheduleRefresh();
    }
  }
  function onPointerDown(event: PointerEvent) {
    if (!event.isTrusted || event.button !== 0 || !event.isPrimary) return;
    void submitPointer(
      isDragTarget(event)
        ? { phase: "down", x: event.clientX, y: event.clientY }
        : { phase: "reset" },
    );
  }
  function onWindowBlur() {
    void submitPointer({ phase: "reset" });
  }
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
    for (const control of document.querySelectorAll<HTMLButtonElement>(
      "button" + controlSelector,
    )) {
      if (!control.disabled) {
        disabledControls.add(control);
        control.disabled = true;
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
  window.addEventListener("blur", onWindowBlur);
  window.addEventListener("focus", scheduleRefresh);
  document.addEventListener("pointerdown", onPointerDown, true);
  document.addEventListener("click", onControlClick, true);
  function dispose() {
    if (disposed) return;
    disposed = true;
    stateEpoch++;
    refreshDirty = false;
    unsubscribeResize();
    window.removeEventListener("pagehide", dispose);
    window.removeEventListener("blur", onWindowBlur);
    window.removeEventListener("focus", scheduleRefresh);
    document.removeEventListener("pointerdown", onPointerDown, true);
    document.removeEventListener("click", onControlClick, true);
    releaseControls();
    const detachedGeneration = generation;
    generation = null;
    clearEnvironment();
    if (detachedGeneration) void disconnect(detachedGeneration);
  }
  return dispose;
}
