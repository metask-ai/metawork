import type { HTMLAttributes, ReactNode, RefObject } from "react";

import { Button } from "../ui/button.tsx";
import { cn } from "../ui/utils.ts";

export function Conversation({
  className,
  viewportRef,
  onViewportScroll,
  children,
  jumpToLatest,
  ...props
}: HTMLAttributes<HTMLElement> & {
  viewportRef?: RefObject<HTMLDivElement | null>;
  onViewportScroll?: () => void;
  children: ReactNode;
  jumpToLatest?: {
    label: string;
    onClick: () => void;
  };
}) {
  return (
    <section className={cn("ai-conversation", className)} {...props}>
      <div
        ref={viewportRef}
        className="ai-conversation-viewport"
        onScroll={onViewportScroll}
      >
        <div className="ai-conversation-content">{children}</div>
      </div>
      {jumpToLatest && (
        <Button
          type="button"
          variant="secondary"
          size="sm"
          className="ai-conversation-jump"
          onClick={jumpToLatest.onClick}
        >
          {jumpToLatest.label}
        </Button>
      )}
    </section>
  );
}
