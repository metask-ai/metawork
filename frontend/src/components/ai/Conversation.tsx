import type {
  HTMLAttributes,
  ReactNode,
  RefObject,
  SyntheticEvent,
} from "react";

import { Button } from "../ui/button.tsx";
import { Icon } from "../ui/Icon.tsx";
import { Tooltip } from "../ui/tooltip.tsx";
import { cn } from "../ui/utils.ts";

/** React bubbles a menu of the content up to here, which is not inside it. */
function inside<E extends SyntheticEvent<HTMLDivElement>>(
  handler: ((event: E) => void) | undefined,
) {
  return (
    handler &&
    ((event: E) => {
      if (event.currentTarget.contains(event.target as Node)) handler(event);
    })
  );
}

export function Conversation({
  className,
  viewportRef,
  onViewportScroll,
  onViewportWheel,
  onViewportKeyDown,
  onViewportPointerDown,
  children,
  jumpToLatest,
  rail,
  ...props
}: HTMLAttributes<HTMLElement> & {
  viewportRef?: RefObject<HTMLDivElement | null>;
  onViewportScroll?: () => void;
  onViewportWheel?: HTMLAttributes<HTMLDivElement>["onWheel"];
  onViewportKeyDown?: HTMLAttributes<HTMLDivElement>["onKeyDown"];
  onViewportPointerDown?: HTMLAttributes<HTMLDivElement>["onPointerDown"];
  children: ReactNode;
  jumpToLatest?: {
    label: string;
    onClick: () => void;
  };
  /** Navigation overlaid on the left edge, outside the scrolling content. */
  rail?: ReactNode;
}) {
  return (
    <section className={cn("ai-conversation", className)} {...props}>
      <div
        ref={viewportRef}
        className="ai-conversation-viewport"
        onScroll={onViewportScroll}
        onWheel={inside(onViewportWheel)}
        onKeyDown={inside(onViewportKeyDown)}
        onPointerDown={inside(onViewportPointerDown)}
        tabIndex={0}
      >
        <div className="ai-conversation-content">{children}</div>
      </div>
      {rail}
      {jumpToLatest && (
        <Tooltip.Root>
          <Tooltip.Trigger
            render={
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="ai-conversation-jump"
                aria-label={jumpToLatest.label}
                onClick={jumpToLatest.onClick}
              />
            }
          >
            <Icon name="arrow-down" />
          </Tooltip.Trigger>
          <Tooltip.Portal>
            <Tooltip.Positioner side="top">
              <Tooltip.Popup>{jumpToLatest.label}</Tooltip.Popup>
            </Tooltip.Positioner>
          </Tooltip.Portal>
        </Tooltip.Root>
      )}
    </section>
  );
}
