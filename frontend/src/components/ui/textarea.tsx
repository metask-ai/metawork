import { forwardRef, type TextareaHTMLAttributes } from "react";

import { cn, controlBase, focusRing } from "./utils.ts";

export const Textarea = forwardRef<
  HTMLTextAreaElement,
  TextareaHTMLAttributes<HTMLTextAreaElement>
>(({ className, ...props }, ref) => (
  <textarea
    ref={ref}
    className={cn(
      "min-h-24 w-full resize-y rounded-[7px] px-3 py-2 text-sm",
      controlBase,
      focusRing,
      className,
    )}
    {...props}
  />
));
Textarea.displayName = "Textarea";
