import {
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
  sendEnabled,
  slash,
  onSubmit,
  onNavigateHistory,
}: {
  sendEnabled: boolean;
  slash: {
    open: boolean;
    canChoose: boolean;
    move: (direction: 1 | -1) => void;
    choose: () => void;
    dismiss: () => void;
  };
  onSubmit: () => void;
  onNavigateHistory: (direction: 1 | -1) => boolean;
}) {
  // Composition belongs to the focused DOM editor, including New-task handoff.
  const compositionTarget = useRef<EventTarget | null>(null);
  const [composing, setComposing] = useState(false);

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
    onTextKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) =>
      handleInputKeyDown(event, "text"),
    onSkillKeyDown: (event: KeyboardEvent<HTMLInputElement>) =>
      handleInputKeyDown(event, "skill"),
    onCompositionStartCapture(event: CompositionEvent<HTMLElement>) {
      compositionTarget.current = event.target;
      setComposing(true);
    },
    onCompositionEndCapture(event: CompositionEvent<HTMLElement>) {
      if (compositionTarget.current === event.target) clearComposition();
    },
    onBlurCapture(event: FocusEvent<HTMLElement>) {
      if (compositionTarget.current === event.target) clearComposition();
    },
  };
}
