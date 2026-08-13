import { Dialog as BaseDialog } from "@base-ui/react/dialog";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Dialog = {
  Root: BaseDialog.Root,
  Trigger: ({ className, ...props }: ComponentProps<typeof BaseDialog.Trigger>) => (
    <BaseDialog.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: BaseDialog.Portal,
  Backdrop: ({ className, ...props }: ComponentProps<typeof BaseDialog.Backdrop>) => (
    <BaseDialog.Backdrop className={cn("fixed inset-0 z-50 bg-black/45 transition-opacity data-ending-style:opacity-0 data-starting-style:opacity-0", className)} {...props} />
  ),
  Popup: ({ className, ...props }: ComponentProps<typeof BaseDialog.Popup>) => (
    <BaseDialog.Popup className={cn("fixed top-1/2 left-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[min(32rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 flex-col gap-4 overflow-y-auto rounded-[12px] border border-(--ui-border) bg-(--ui-surface-panel) p-6 text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none transition-[scale,opacity] data-ending-style:scale-95 data-ending-style:opacity-0 data-starting-style:scale-95 data-starting-style:opacity-0", className)} {...props} />
  ),
  Title: ({ className, ...props }: ComponentProps<typeof BaseDialog.Title>) => (
    <BaseDialog.Title className={cn("text-base font-semibold", className)} {...props} />
  ),
  Description: ({ className, ...props }: ComponentProps<typeof BaseDialog.Description>) => (
    <BaseDialog.Description className={cn("text-sm text-(--ui-content-muted)", className)} {...props} />
  ),
  Close: ({ className, ...props }: ComponentProps<typeof BaseDialog.Close>) => (
    <BaseDialog.Close className={cn(focusRing, className)} {...props} />
  ),
};
