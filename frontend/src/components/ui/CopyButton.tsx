import { useEffect, useRef, useState } from "react";

import { Button, type ButtonProps } from "./button.tsx";
import { Icon } from "./Icon.tsx";
import { Tooltip } from "./tooltip.tsx";

type CopyState = "idle" | "copying" | "copied" | "failed";

export function CopyButton({
  copyLabel,
  copiedLabel,
  failedLabel,
  onCopy,
  disabled,
  ...props
}: Omit<ButtonProps, "children" | "onClick"> & {
  copyLabel: string;
  copiedLabel: string;
  failedLabel: string;
  onCopy: () => void | Promise<unknown>;
}) {
  const [state, setState] = useState<CopyState>("idle");
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const attempt = useRef(0);

  function clearResetTimer() {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
  }

  useEffect(
    () => () => {
      attempt.current += 1;
      clearResetTimer();
    },
    [],
  );

  async function copy() {
    clearResetTimer();
    const currentAttempt = ++attempt.current;
    setState("copying");
    try {
      await onCopy();
      if (attempt.current !== currentAttempt) return;
      setState("copied");
      timer.current = setTimeout(() => setState("idle"), 1200);
    } catch {
      if (attempt.current !== currentAttempt) return;
      setState("failed");
      timer.current = setTimeout(() => setState("idle"), 1500);
    }
  }

  const label =
    state === "copied"
      ? copiedLabel
      : state === "failed"
        ? failedLabel
        : copyLabel;

  return (
    <Tooltip.Root>
      <Tooltip.Trigger
        render={
          <Button
            type="button"
            variant="ghost"
            size="icon"
            data-copy-state={state}
            aria-label={label}
            aria-busy={state === "copying" || undefined}
            disabled={disabled || state === "copying"}
            onClick={copy}
            {...props}
          />
        }
      >
        <Icon
          name={
            state === "copied"
              ? "check"
              : state === "failed"
                ? "warning"
                : "copy"
          }
        />
        <span className="sr-only" aria-live="polite">
          {label}
        </span>
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Positioner side="top">
          <Tooltip.Popup>{label}</Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}
