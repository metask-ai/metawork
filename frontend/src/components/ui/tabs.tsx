import { Tabs as BaseTabs } from "@base-ui/react/tabs";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Tabs = {
  Root: BaseTabs.Root,
  List: ({ className, ...props }: ComponentProps<typeof BaseTabs.List>) => (
    <BaseTabs.List className={cn("flex gap-1 border-b border-(--ui-border)", className)} {...props} />
  ),
  Tab: ({ className, ...props }: ComponentProps<typeof BaseTabs.Tab>) => (
    <BaseTabs.Tab className={cn("relative -mb-px px-3 py-2 text-sm text-(--ui-content-muted) outline-none data-active:border-b-2 data-active:border-(--ui-action-primary) data-active:text-(--ui-content-primary) hover:text-(--ui-content-primary)", focusRing, className)} {...props} />
  ),
  Panel: ({ className, ...props }: ComponentProps<typeof BaseTabs.Panel>) => (
    <BaseTabs.Panel className={cn("pt-4 outline-none", focusRing, className)} {...props} />
  ),
  Indicator: BaseTabs.Indicator,
};
