import type { TextareaHTMLAttributes } from "react";

import { cn, controlBase, focusRing } from "./utils.ts";

export function Textarea({ className, ...props }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn("min-h-24 w-full resize-y rounded-[7px] px-3 py-2 text-sm", controlBase, focusRing, className)}
      {...props}
    />
  );
}
