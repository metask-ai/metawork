import { useId, useState, type ReactNode } from "react";
import { Button } from "./button.tsx";
import { Icon } from "./Icon.tsx";

/** Presentation only: the caller owns validity, dismissal and action eligibility. */
export function FeedbackNotice({
  title,
  message,
  diagnostic,
  detailsLabel,
  dismissLabel,
  onDismiss,
  actions,
  pending = false,
}: {
  title: string;
  message?: string;
  diagnostic?: string;
  detailsLabel: string;
  dismissLabel?: string;
  onDismiss?: () => void;
  actions?: ReactNode;
  pending?: boolean;
}) {
  const detailsId = useId();
  const [expanded, setExpanded] = useState(false);
  return (
    <section
      className="feedback-notice"
      aria-label={title}
      data-pending={pending}
    >
      <div className="feedback-notice-heading">
        <Icon name={pending ? "info" : "warning"} />
        <strong>{title}</strong>
        {onDismiss && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            aria-label={dismissLabel}
            onClick={onDismiss}
          >
            <Icon name="close" />
          </Button>
        )}
      </div>
      {message && <p>{message}</p>}
      {(actions || diagnostic) && (
        <div className="feedback-notice-actions">
          {actions}
          {diagnostic && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              aria-expanded={expanded}
              aria-controls={detailsId}
              onClick={() => setExpanded((value) => !value)}
            >
              {detailsLabel}
            </Button>
          )}
        </div>
      )}
      {diagnostic && expanded && (
        <pre id={detailsId} className="feedback-notice-details">
          {diagnostic}
        </pre>
      )}
    </section>
  );
}
