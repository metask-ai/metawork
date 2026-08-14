import type {
  ButtonHTMLAttributes,
  FormHTMLAttributes,
  HTMLAttributes,
  ReactNode,
  TextareaHTMLAttributes,
} from "react";

import { cn, focusRing } from "../ui/utils.ts";

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
}: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn("ai-prompt-input-textarea", focusRing, className)}
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
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  label: string;
  children?: ReactNode;
}) {
  return (
    <button
      type="submit"
      aria-label={label}
      className={cn("ai-prompt-input-submit", focusRing, className)}
      {...props}
    >
      {children ?? label}
    </button>
  );
}
