import type { HTMLAttributes, ReactNode } from "react";
import { memo } from "react";

import { Button, type ButtonProps } from "../ui/button.tsx";
import { cn } from "../ui/utils.ts";

export type AiMessageRole = "user" | "assistant" | "system";

/**
 * Adapted from Vercel AI Elements 1.9.0.
 * Source: https://elements.ai-sdk.dev/api/registry/message.json
 *
 * AI SDK's `UIMessage` and Streamdown are deliberately not runtime
 * dependencies. Product code passes its already-decoded projection text into
 * this presentation component.
 */
export function Message({
  from,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  from: AiMessageRole;
  children: ReactNode;
}) {
  return (
    <article
      className={cn("ai-message", `ai-message-${from}`, className)}
      data-from={from}
      {...props}
    >
      {children}
    </article>
  );
}

export function MessageContent({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-message-content", className)} {...props}>
      {children}
    </div>
  );
}

export function MessageActions({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-message-actions", className)} {...props}>
      {children}
    </div>
  );
}

export function MessageAction({
  tooltip,
  label,
  className,
  children,
  ...props
}: ButtonProps & {
  tooltip?: string;
  label?: string;
}) {
  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      className={cn("ai-message-action", className)}
      aria-label={label ?? tooltip}
      title={tooltip}
      {...props}
    >
      {children}
    </Button>
  );
}

export type MessageResponseProps = HTMLAttributes<HTMLDivElement> & {
  streaming?: boolean;
  children: ReactNode;
};

/**
 * The upstream component delegates Markdown to Streamdown. MetaWork keeps
 * this baseline dependency-free and text-oriented; a Markdown renderer can
 * be introduced behind the same component contract later.
 */
export const MessageResponse = memo(function MessageResponse({
  className,
  children,
  streaming = false,
  ...props
}: MessageResponseProps) {
  return (
    <div
      className={cn("ai-message-response", className)}
      data-streaming={streaming}
      {...props}
    >
      {children}
    </div>
  );
});
