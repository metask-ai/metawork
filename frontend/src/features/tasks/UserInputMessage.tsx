import type { ReactNode } from "react";
import { Message } from "../../components/ai/index.ts";

/** The same user-message surface serves local, waiting and executing input. */
export function UserInputMessage({
  operationId,
  inputId,
  readingId,
  className = "",
  children,
  footer,
  notice,
}: {
  operationId?: string;
  inputId?: string;
  readingId?: string;
  className?: string;
  children: ReactNode;
  footer?: ReactNode;
  notice?: ReactNode;
}) {
  return (
    <div
      className={`additional-input ${className}`.trim()}
      data-operation-id={operationId}
      data-input-id={inputId}
      data-reading-id={
        readingId ?? (operationId ? `submission:${operationId}` : undefined)
      }
    >
      <Message role="user" tabIndex={-1} className="focus-ring">
        {children}
      </Message>
      {footer}
      {notice}
    </div>
  );
}
