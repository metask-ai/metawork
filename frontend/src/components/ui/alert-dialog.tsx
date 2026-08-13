import { AlertDialog as BaseAlertDialog } from "@base-ui/react/alert-dialog";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const AlertDialog = {
  Root: BaseAlertDialog.Root,
  Trigger: ({ className, ...props }: ComponentProps<typeof BaseAlertDialog.Trigger>) => (
    <BaseAlertDialog.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: BaseAlertDialog.Portal,
  Backdrop: ({ className, ...props }: ComponentProps<typeof BaseAlertDialog.Backdrop>) => (
    <BaseAlertDialog.Backdrop className={cn("fixed inset-0 z-50 bg-black/45", className)} {...props} />
  ),
  Popup: ({ className, ...props }: ComponentProps<typeof BaseAlertDialog.Popup>) => (
    <BaseAlertDialog.Popup className={cn("fixed top-1/2 left-1/2 z-50 flex w-[min(28rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 flex-col gap-4 rounded-[12px] border border-(--ui-border) bg-(--ui-surface-panel) p-6 text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none", className)} {...props} />
  ),
  Title: ({ className, ...props }: ComponentProps<typeof BaseAlertDialog.Title>) => (
    <BaseAlertDialog.Title className={cn("text-base font-semibold", className)} {...props} />
  ),
  Description: ({ className, ...props }: ComponentProps<typeof BaseAlertDialog.Description>) => (
    <BaseAlertDialog.Description className={cn("text-sm text-(--ui-content-muted)", className)} {...props} />
  ),
  Close: ({ className, ...props }: ComponentProps<typeof BaseAlertDialog.Close>) => (
    <BaseAlertDialog.Close className={cn(focusRing, className)} {...props} />
  ),
};
