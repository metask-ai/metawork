import type { ReactNode } from "react";
import { Message } from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";

export function SkillMessageBody({
  skill,
}: {
  skill: {
    displayName: string;
    invocationName: string;
    argumentValues: readonly string[];
  };
}) {
  return (
    <div className="task-skill-input">
      <span className="skill-message-tag">
        <Icon name="skills" />
        {skill.displayName || skill.invocationName}
      </span>
      {skill.argumentValues.length > 0 && (
        <p className="task-input-copy">{skill.argumentValues.join("\n")}</p>
      )}
    </div>
  );
}

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
