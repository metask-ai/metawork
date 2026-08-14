import { useId } from "react";

/**
 * AI-facing code and tool-output presentation primitive.
 *
 * Product features own the labels and the source of the already projected
 * value; this component only owns bounded, accessible presentation.
 */
export function CodeBlock({ label, value }: { label: string; value: string }) {
  const labelId = useId();
  return (
    <div>
      <p
        id={labelId}
        className="mb-1 font-mono text-[9px] tracking-[0.14em] text-ui-muted uppercase"
      >
        {label}
      </p>
      <pre
        className="code-block-preview"
        tabIndex={0}
        aria-labelledby={labelId}
      >
        {value}
      </pre>
    </div>
  );
}
