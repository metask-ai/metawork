import { Dialog as BaseDialog } from "@base-ui/react/dialog";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

// Edge-anchored dialog. Same Base UI dialog semantics (focus trap, dismiss,
// ARIA) as `Dialog`; only the resting geometry differs. Customize through
// Tailwind utilities on `className` — product stylesheets must not fight the
// defaults with custom-class overrides.
const drawerSides = {
  right:
    "right-0 border-l data-ending-style:translate-x-full data-starting-style:translate-x-full",
  left: "left-0 border-r data-ending-style:-translate-x-full data-starting-style:-translate-x-full",
} as const;

type DrawerSide = keyof typeof drawerSides;

type DrawerPopupProps = ComponentProps<typeof BaseDialog.Popup> & {
  side?: DrawerSide;
};

export const Drawer = {
  Root: BaseDialog.Root,
  Trigger: ({
    className,
    ...props
  }: ComponentProps<typeof BaseDialog.Trigger>) => (
    <BaseDialog.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: BaseDialog.Portal,
  Backdrop: ({
    className,
    ...props
  }: ComponentProps<typeof BaseDialog.Backdrop>) => (
    <BaseDialog.Backdrop
      className={cn(
        "fixed inset-0 z-50 bg-(--ui-overlay-scrim) transition-opacity motion-reduce:transition-none data-ending-style:opacity-0 data-starting-style:opacity-0",
        className,
      )}
      {...props}
    />
  ),
  Popup: ({ className, side = "right", ...props }: DrawerPopupProps) => (
    <BaseDialog.Popup
      className={cn(
        "fixed inset-y-0 z-50 flex h-full w-[min(28rem,calc(100vw-2rem))] translate-none flex-col overflow-hidden border-(--ui-border) bg-(--ui-surface-panel) text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none transition-[translate,opacity] motion-reduce:transition-none data-ending-style:opacity-0 data-starting-style:opacity-0",
        drawerSides[side],
        className,
      )}
      {...props}
    />
  ),
  Header: ({ className, ...props }: ComponentProps<"header">) => (
    <header
      className={cn(
        "flex items-start justify-between gap-4 border-b border-(--ui-border) p-6",
        className,
      )}
      {...props}
    />
  ),
  Body: ({ className, ...props }: ComponentProps<"div">) => (
    <div
      className={cn(
        "flex-1 overflow-y-auto p-6 [scrollbar-gutter:stable]",
        className,
      )}
      {...props}
    />
  ),
  Footer: ({ className, ...props }: ComponentProps<"footer">) => (
    <footer
      className={cn(
        "flex items-center justify-end gap-3 border-t border-(--ui-border) p-6",
        className,
      )}
      {...props}
    />
  ),
  Title: ({ className, ...props }: ComponentProps<typeof BaseDialog.Title>) => (
    <BaseDialog.Title
      className={cn("text-base font-semibold", className)}
      {...props}
    />
  ),
  Description: ({
    className,
    ...props
  }: ComponentProps<typeof BaseDialog.Description>) => (
    <BaseDialog.Description
      className={cn("text-sm text-(--ui-content-muted)", className)}
      {...props}
    />
  ),
  Close: ({ className, ...props }: ComponentProps<typeof BaseDialog.Close>) => (
    <BaseDialog.Close className={cn(focusRing, className)} {...props} />
  ),
};
