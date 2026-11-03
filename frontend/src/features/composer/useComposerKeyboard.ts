import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CompositionEvent,
  type FocusEvent,
  type KeyboardEvent,
} from "react";

import { desktopPlatform, isInputMethodKey } from "../../platform/keyboard.ts";

function bareKey(event: KeyboardEvent) {
  return !event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey;
}

function submitKey(event: KeyboardEvent) {
  if (event.key !== "Enter" || event.shiftKey || event.altKey) return false;
  if (bareKey(event)) return true;
  return desktopPlatform() === "macos"
    ? event.metaKey && !event.ctrlKey
    : event.ctrlKey && !event.metaKey;
}

export function useComposerKeyboard({
  draftScope,
  sendEnabled,
  stopAction,
  stopDisabled,
  slash,
  onSubmit,
  onStop,
  onNavigateHistory,
}: {
  draftScope: string;
  sendEnabled: boolean;
  stopAction: "run" | "compact" | null;
  stopDisabled: boolean;
  slash: {
    open: boolean;
    canChoose: boolean;
    move: (direction: 1 | -1) => void;
    choose: () => void;
    dismiss: () => void;
  };
  onSubmit: () => void;
  onStop: () => void;
  onNavigateHistory: (direction: 1 | -1) => boolean;
}) {
  // Composition belongs to the focused DOM editor, including New-task handoff.
  const compositionTarget = useRef<EventTarget | null>(null);
  const [composing, setComposing] = useState(false);
  const confirmationRef = useRef<{ scope: string; deadline: number } | null>(
    null,
  );
  const [confirmation, setConfirmation] =
    useState<typeof confirmationRef.current>(null);
  const confirmationTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const canStop = stopAction !== null && !stopDisabled;

  const clearConfirmation = useCallback(() => {
    if (confirmationTimer.current !== null)
      clearTimeout(confirmationTimer.current);
    confirmationTimer.current = null;
    confirmationRef.current = null;
    setConfirmation(null);
  }, []);

  useLayoutEffect(clearConfirmation, [
    draftScope,
    stopAction,
    stopDisabled,
    clearConfirmation,
  ]);
  useEffect(() => {
    window.addEventListener("blur", clearConfirmation);
    return () => {
      window.removeEventListener("blur", clearConfirmation);
      if (confirmationTimer.current !== null)
        clearTimeout(confirmationTimer.current);
    };
  }, [clearConfirmation]);

  function clearComposition() {
    compositionTarget.current = null;
    setComposing(false);
  }

  function inputMethodKey(event: KeyboardEvent) {
    return isInputMethodKey(
      event.nativeEvent,
      compositionTarget.current !== null,
    );
  }

  function handleInputKeyDown(event: KeyboardEvent, kind: "text" | "skill") {
    if (event.defaultPrevented || inputMethodKey(event)) return;
    if (kind === "text" && slash.open) {
      if (bareKey(event)) {
        if (event.key === "ArrowUp" || event.key === "ArrowDown") {
          event.preventDefault();
          slash.move(event.key === "ArrowUp" ? -1 : 1);
          return;
        }
        if (event.key === "Escape") {
          event.preventDefault();
          slash.dismiss();
          return;
        }
        if (event.key === "Enter" || (event.key === "Tab" && slash.canChoose)) {
          event.preventDefault();
          if (slash.canChoose) slash.choose();
          return;
        }
      }
      if (
        event.key === "Tab" &&
        !event.metaKey &&
        !event.ctrlKey &&
        !event.altKey
      )
        slash.dismiss();
      // Modified Enter must not submit unresolved Slash; Shift+Enter stays native.
      return;
    }
    if (
      kind === "text" &&
      bareKey(event) &&
      (event.key === "ArrowUp" || event.key === "ArrowDown") &&
      onNavigateHistory(event.key === "ArrowUp" ? -1 : 1)
    ) {
      event.preventDefault();
      return;
    }
    if (sendEnabled && submitKey(event)) {
      event.preventDefault();
      onSubmit();
    }
  }

  return {
    composing,
    stopConfirming: canStop && confirmation?.scope === draftScope,
    onKeyDownCapture(event: KeyboardEvent<HTMLElement>) {
      if (event.key !== "Escape" || !bareKey(event) || inputMethodKey(event))
        clearConfirmation();
    },
    onKeyDown(event: KeyboardEvent<HTMLElement>) {
      if (
        event.defaultPrevented ||
        inputMethodKey(event) ||
        event.key !== "Escape" ||
        !bareKey(event) ||
        !canStop
      )
        return;
      // Nested controls keep their own Escape semantics, including portals.
      if (
        (event.target as Element).closest(
          '[role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"]',
        )
      )
        return;
      event.preventDefault();
      if (event.repeat) return;
      const now = performance.now();
      const pending = confirmationRef.current;
      if (pending?.scope === draftScope && now < pending.deadline) {
        clearConfirmation();
        onStop();
        return;
      }
      clearConfirmation();
      const next = { scope: draftScope, deadline: now + 1000 };
      confirmationRef.current = next;
      setConfirmation(next);
      confirmationTimer.current = setTimeout(() => {
        if (confirmationRef.current === next) clearConfirmation();
      }, 1000);
    },
    onPointerDownCapture: clearConfirmation,
    onChangeCapture: clearConfirmation,
    onTextKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) =>
      handleInputKeyDown(event, "text"),
    onSkillKeyDown: (event: KeyboardEvent<HTMLInputElement>) =>
      handleInputKeyDown(event, "skill"),
    onCompositionStartCapture(event: CompositionEvent<HTMLElement>) {
      clearConfirmation();
      compositionTarget.current = event.target;
      setComposing(true);
    },
    onCompositionEndCapture(event: CompositionEvent<HTMLElement>) {
      if (compositionTarget.current === event.target) clearComposition();
    },
    onFocusCapture(event: FocusEvent<HTMLElement>) {
      // Removing an editor need not emit blur or compositionend.
      if (
        compositionTarget.current !== null &&
        compositionTarget.current !== event.target
      )
        clearComposition();
    },
    onBlurCapture(event: FocusEvent<HTMLElement>) {
      if (compositionTarget.current === event.target) clearComposition();
      if (!event.currentTarget.contains(event.relatedTarget as Node | null))
        clearConfirmation();
    },
  };
}
