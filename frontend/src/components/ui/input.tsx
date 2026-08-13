import { Input as BaseInput } from "@base-ui/react/input";
import type { ComponentProps } from "react";

import { cn, controlBase, focusRing } from "./utils.ts";

export type InputProps = ComponentProps<typeof BaseInput>;

export function Input({ className, ...props }: InputProps) {
  return (
    <BaseInput
      className={cn("h-9 w-full rounded-[7px] px-3 text-sm", controlBase, focusRing, className)}
      {...props}
    />
  );
}
