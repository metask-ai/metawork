import { useState, type ReactNode } from "react";

/** Low-frequency source diagnostics, independent of dismissible notices. */
export function DiagnosticDisclosure({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  const [expanded, setExpanded] = useState(false);
  return (
    <details
      className="feedback-diagnostics"
      onToggle={(event) => setExpanded(event.currentTarget.open)}
    >
      <summary className="focus-ring" tabIndex={0}>
        {label}
      </summary>
      {expanded && children}
    </details>
  );
}
