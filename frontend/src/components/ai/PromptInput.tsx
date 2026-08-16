import type {
  ComponentProps,
  FormHTMLAttributes,
  HTMLAttributes,
  ReactNode,
} from "react";

import { Button, type ButtonProps } from "../ui/button.tsx";
import { Textarea } from "../ui/textarea.tsx";
import { cn } from "../ui/utils.ts";

export function PromptInput({
  className,
  children,
  ...props
}: FormHTMLAttributes<HTMLFormElement> & { children: ReactNode }) {
  return (
    <form className={cn("ai-prompt-input", className)} {...props}>
      {children}
    </form>
  );
}

export function PromptInputTextarea({
  className,
  ...props
}: ComponentProps<typeof Textarea>) {
  return (
    <Textarea
      className={cn("ai-prompt-input-textarea", className)}
      {...props}
    />
  );
}

export function PromptInputFooter({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-prompt-input-footer", className)} {...props}>
      {children}
    </div>
  );
}

export function PromptInputSubmit({
  label,
  className,
  children,
  ...props
}: ButtonProps & {
  label: string;
  children?: ReactNode;
}) {
  return (
    <Button
      type="submit"
      variant="primary"
      size="sm"
      aria-label={label}
      className={cn("ai-prompt-input-submit", className)}
      {...props}
    >
      {children ?? label}
    </Button>
  );
}
