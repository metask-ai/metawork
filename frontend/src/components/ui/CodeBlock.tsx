import { useId } from "react";

export function CodeBlock({ label, value }: { label: string; value: string }) {
  const labelId = useId();
  return (
    <div>
      <p
        id={labelId}
        className="mb-1 font-mono text-[9px] tracking-[0.14em] text-muted uppercase"
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
