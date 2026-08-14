import type { HTMLAttributes, ReactNode } from "react";
import { memo } from "react";

import { Button, type ButtonProps } from "../ui/button.tsx";
import { cn } from "../ui/utils.ts";
import { Markdown } from "./Markdown.tsx";

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
 * Markdown rendering stays product-owned. It uses the AI UI component
 * baseline without introducing AI SDK transport or provider runtime.
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
      {typeof children === "string" ? (
        <Markdown>{children}</Markdown>
      ) : (
        children
      )}
    </div>
  );
});
