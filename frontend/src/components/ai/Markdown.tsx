import type { ComponentPropsWithoutRef } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { CodeBlock } from "./CodeBlock.tsx";

function safeHref(href: string | undefined): string | null {
  if (!href) return null;
  if (!href.includes(":") && !href.startsWith("//")) return href;
  try {
    const url = new URL(href, "https://metawork.invalid");
    if (["http:", "https:", "mailto:"].includes(url.protocol)) return href;
  } catch {
    return null;
  }
  return null;
}

export function Markdown({
  className,
  children,
}: {
  className?: string;
  children: string;
}) {
  return (
    <div className={className ? `ai-markdown ${className}` : "ai-markdown"}>
      <ReactMarkdown
        skipHtml
        remarkPlugins={[remarkGfm]}
        components={{
          pre: ({ children: content }) => <>{content}</>,
          code: ({ className: codeClassName, children: content, ...props }) => {
            const value = String(content).replace(/\n$/, "");
            const language = codeClassName?.match(/language-(\w+)/)?.[1];
            if (!language && !value.includes("\n")) {
              return (
                <code className={codeClassName} {...props}>
                  {content}
                </code>
              );
            }
            return <CodeBlock label={language ?? "code"} value={value} />;
          },
          a: ({ href, children: content, ...props }) => {
            const hrefValue = safeHref(href);
            if (!hrefValue) return <span>{content}</span>;
            return (
              <a
                {...props}
                href={hrefValue}
                target="_blank"
                rel="noreferrer noopener"
              >
                {content}
              </a>
            );
          },
        }}
      >
        {children}
      </ReactMarkdown>
    </div>
  );
}

export type MarkdownProps = ComponentPropsWithoutRef<typeof Markdown>;
