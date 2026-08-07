import type { NativeBridge } from "./client.ts";
import { commands } from "./commands.ts";
import {
  assertDisconnected,
  decodeWindowChromeEnvironment,
  type WindowChromeEnvironment,
} from "./decode-contracts.ts";

const candidateSelector = "[data-metawork-window-drag]";
const controlSelector = "[data-metawork-window-control]";
const exclusionSelector =
  "button, input, select, textarea, label, details, a, [contenteditable='true'], [data-metawork-window-drag-exclude]";
const maxExclusions = 32;
const controlActions = new Set(["minimize", "toggle_maximize", "close"]);

type ChromeRegion = {
  x: number;
  y: number;
  width: number;
  height: number;
  exclusion: boolean;
};

export function installWindowChromeBridge() {
  const bridge = window.zero;
  if (!bridge) return () => undefined;

  let generation: string | null = null;
  let environment: WindowChromeEnvironment | null = null;
  let animationFrame: number | null = null;
  let syncInFlight = false;
  let syncDirty = false;
  let dragSynchronized = false;
  let observedCandidate: Element | null = null;

  const resizeObserver = new ResizeObserver(() => scheduleSync());
  const mutationObserver = new MutationObserver(() => scheduleSync());

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
      `${value.insets.top}px`,
    );
    root.style.setProperty(
      "--metawork-window-chrome-leading",
      `${value.insets.left}px`,
    );
    root.style.setProperty(
      "--metawork-window-chrome-trailing",
      `${value.insets.right}px`,
    );
    root.style.setProperty(
      "--metawork-window-chrome-buttons-x",
      `${value.buttons.x}px`,
    );
    root.style.setProperty(
      "--metawork-window-chrome-buttons-width",
      `${value.buttons.width}px`,
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

  function candidate() {
    const candidates = document.querySelectorAll(candidateSelector);
    return candidates.length === 1 ? candidates[0] : null;
  }

  function finiteRect(rect: DOMRect): ChromeRegion | null {
    const values = [rect.x, rect.y, rect.width, rect.height];
    if (
      values.some((value) => !Number.isFinite(value) || value < 0) ||
      rect.width <= 0 ||
      rect.height <= 0
    )
      return null;
    return {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
      exclusion: false,
    };
  }

  function intersection(outer: DOMRect, inner: DOMRect): ChromeRegion | null {
    const left = Math.max(outer.left, inner.left);
    const top = Math.max(outer.top, inner.top);
    const right = Math.min(outer.right, inner.right);
    const bottom = Math.min(outer.bottom, inner.bottom);
    if (right <= left || bottom <= top) return null;
    return {
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
      exclusion: true,
    };
  }

  function regionsForCandidate(value: Element | null): ChromeRegion[] {
    if (!value) return [];
    const candidateRect = value.getBoundingClientRect();
    const dragRegion = finiteRect(candidateRect);
    if (!dragRegion) return [];
    const exclusions = [...document.querySelectorAll(exclusionSelector)]
      .map((element) =>
        intersection(candidateRect, element.getBoundingClientRect()),
      )
      .filter((region): region is ChromeRegion => region !== null);
    if (exclusions.length > maxExclusions) return [];
    return [dragRegion, ...exclusions];
  }

  function observeCandidate(value: Element | null) {
    if (value === observedCandidate) return;
    if (observedCandidate) resizeObserver.unobserve(observedCandidate);
    observedCandidate = value;
    if (observedCandidate) resizeObserver.observe(observedCandidate);
  }

  async function sync() {
    if (!generation || syncInFlight || !syncDirty) return;
    syncDirty = false;
    const requestGeneration = generation;
    syncInFlight = true;
    try {
      const activeCandidate = candidate();
      observeCandidate(activeCandidate);
      const value = decodeWindowChromeEnvironment(
        await bridge.invoke(commands.windowChromeSync, {
          generation: requestGeneration,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight,
          regions: regionsForCandidate(activeCandidate),
        }),
      );
      if (
        generation === requestGeneration &&
        value.generation === requestGeneration
      ) {
        applyEnvironment(value);
        dragSynchronized = true;
      }
    } catch {
      if (generation === requestGeneration) dragSynchronized = false;
    } finally {
      syncInFlight = false;
      if (syncDirty) scheduleFrame();
    }
  }

  function scheduleSync() {
    if (!generation) return;
    syncDirty = true;
    if (syncInFlight || animationFrame !== null) return;
    scheduleFrame();
  }

  function scheduleFrame() {
    if (animationFrame !== null) return;
    animationFrame = window.requestAnimationFrame(() => {
      animationFrame = null;
      void sync();
    });
  }

  async function disconnect(
    nativeBridge: NativeBridge,
    expectedGeneration: string | null = generation,
  ) {
    const current = expectedGeneration;
    if (!current || generation !== current) return;
    generation = null;
    syncDirty = false;
    dragSynchronized = false;
    clearEnvironment();
    try {
      assertDisconnected(
        await nativeBridge.invoke(commands.windowChromeDisconnect, {
          generation: current,
        }),
        current,
      );
    } catch {
      // The Host also clears on the next document connect and at teardown.
    }
  }

  function onPointerDown(event: PointerEvent) {
    if (
      !environment?.livePointerDrag ||
      !dragSynchronized ||
      !generation ||
      !event.isTrusted ||
      event.button !== 0 ||
      !event.isPrimary
    )
      return;
    const requestGeneration = generation;
    const activeCandidate = candidate();
    const target = event.target instanceof Element ? event.target : null;
    const bounds = activeCandidate?.getBoundingClientRect();
    if (
      !activeCandidate ||
      !bounds ||
      !target ||
      event.clientX < bounds.left ||
      event.clientX >= bounds.right ||
      event.clientY < bounds.top ||
      event.clientY >= bounds.bottom ||
      target.closest(exclusionSelector)
    )
      return;
    void bridge
      .invoke(commands.windowChromeBeginDrag, {
        generation: requestGeneration,
        x: event.clientX,
        y: event.clientY,
      })
      .then(decodeWindowChromeEnvironment)
      .then((value) => {
        if (
          generation === requestGeneration &&
          value.generation === requestGeneration
        )
          applyEnvironment(value);
      })
      .catch(() => undefined);
  }

  function onControlClick(event: MouseEvent) {
    const target = event.target instanceof Element ? event.target : null;
    const button = target?.closest<HTMLButtonElement>(controlSelector);
    const action = button?.dataset.metaworkWindowControl;
    if (
      !button ||
      !action ||
      !controlActions.has(action) ||
      !environment?.rendererControls ||
      !generation
    )
      return;
    event.preventDefault();
    const requestGeneration = generation;
    for (const control of document.querySelectorAll<HTMLButtonElement>(
      controlSelector,
    ))
      control.disabled = true;
    void bridge
      .invoke(commands.windowChromeControl, {
        generation: requestGeneration,
        action,
      })
      .then(decodeWindowChromeEnvironment)
      .then((value) => {
        if (
          generation === requestGeneration &&
          value.generation === requestGeneration
        )
          applyEnvironment(value);
      })
      .catch(() => undefined)
      .finally(() => {
        for (const control of document.querySelectorAll<HTMLButtonElement>(
          controlSelector,
        ))
          control.disabled = false;
      });
  }

  void bridge
    .invoke(commands.windowChromeConnect, {})
    .then(decodeWindowChromeEnvironment)
    .then((value) => {
      generation = value.generation;
      applyEnvironment(value);
      mutationObserver.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
      });
      scheduleSync();
    })
    .catch(clearEnvironment);

  const unsubscribeResize = bridge.on("resize", scheduleSync);
  const onPageHide = () => void disconnect(bridge);
  window.addEventListener("pagehide", onPageHide, {
    once: true,
  });
  document.addEventListener("pointerdown", onPointerDown, true);
  document.addEventListener("click", onControlClick, true);

  return () => {
    if (animationFrame !== null) window.cancelAnimationFrame(animationFrame);
    resizeObserver.disconnect();
    mutationObserver.disconnect();
    unsubscribeResize();
    window.removeEventListener("pagehide", onPageHide);
    document.removeEventListener("pointerdown", onPointerDown, true);
    document.removeEventListener("click", onControlClick, true);
    void disconnect(bridge);
  };
}
