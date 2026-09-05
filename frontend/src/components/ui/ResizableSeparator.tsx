import { useRef } from "react";

export function ResizableSeparator({
  className,
  label,
  value,
  minimum,
  maximum,
  step,
  reverse = false,
  onChange,
  onCommit,
  onResizeStart,
  onResizeEnd,
}: {
  className?: string;
  label: string;
  value: number;
  minimum: number;
  maximum: number;
  step: number;
  reverse?: boolean;
  onChange: (value: number) => void;
  onCommit: (value: number) => void;
  onResizeStart?: () => void;
  onResizeEnd?: () => void;
}) {
  const current = useRef(value);
  current.current = value;
  const drag = useRef<{
    pointerId: number;
    startX: number;
    startValue: number;
  } | null>(null);

  function update(next: number, commit: boolean) {
    const clamped = Math.min(maximum, Math.max(minimum, next));
    current.current = clamped;
    onChange(clamped);
    if (commit) onCommit(clamped);
  }

  return (
    <div
      className={className}
      role="separator"
      aria-label={label}
      aria-orientation="vertical"
      aria-valuemin={minimum}
      aria-valuemax={maximum}
      aria-valuenow={value}
      tabIndex={0}
      onPointerDown={(event) => {
        event.preventDefault();
        drag.current = {
          pointerId: event.pointerId,
          startX: event.clientX,
          startValue: current.current,
        };
        event.currentTarget.setPointerCapture(event.pointerId);
        onResizeStart?.();
      }}
      onPointerMove={(event) => {
        const active = drag.current;
        if (!active || active.pointerId !== event.pointerId) return;
        const delta = event.clientX - active.startX;
        update(active.startValue + (reverse ? -delta : delta), false);
      }}
      onPointerUp={(event) => {
        if (drag.current?.pointerId !== event.pointerId) return;
        drag.current = null;
        update(current.current, true);
        onResizeEnd?.();
        if (event.currentTarget.hasPointerCapture(event.pointerId))
          event.currentTarget.releasePointerCapture(event.pointerId);
      }}
      onPointerCancel={(event) => {
        if (drag.current?.pointerId !== event.pointerId) return;
        drag.current = null;
        update(current.current, true);
        onResizeEnd?.();
      }}
      onKeyDown={(event) => {
        let next: number | null = null;
        if (event.key === "ArrowLeft")
          next = current.current + (reverse ? step : -step);
        if (event.key === "ArrowRight")
          next = current.current + (reverse ? -step : step);
        if (event.key === "Home") next = minimum;
        if (event.key === "End") next = maximum;
        if (next === null) return;
        event.preventDefault();
        update(next, true);
      }}
    />
  );
}
