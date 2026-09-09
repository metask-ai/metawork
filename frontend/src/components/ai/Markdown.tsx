import {
  createContext,
  useContext,
  type ComponentPropsWithoutRef,
} from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { InlineCode, Link, Parent, Root, RootContent, Text } from "mdast";

import { CodeBlock } from "./CodeBlock.tsx";
import { Button } from "../ui/button.tsx";

export type MarkdownReference = {
  label: string;
  onOpen: (opener: HTMLButtonElement) => void;
};

const ReferenceContext = createContext<
  ReadonlyMap<string, MarkdownReference> | undefined
>(undefined);

function referencePlugin(references: ReadonlyMap<string, MarkdownReference>) {
  const aliases = [...references.keys()]
    .filter(Boolean)
    .sort((a, b) => b.length - a.length);
  const escaped = aliases.map((alias) =>
    alias.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
  );
  const pattern = new RegExp(
    `(?<![\\p{L}\\p{N}_./\\\\~:@%+-])(?:${escaped.join("|")})(?![\\p{L}\\p{N}_/\\\\~:@%+-]|\\.[\\p{L}\\p{N}_])`,
    "gu",
  );
  function link(alias: string, child: Text | InlineCode): Link {
    return {
      type: "link",
      url: "#",
      data: { hProperties: { "data-inline-reference": alias } },
      children: [child],
    };
  }
  return () => (tree: Root) => {
    const definitions = new Map<string, string>();
    function collect(parent: Parent) {
      for (const node of parent.children) {
        if (node.type === "definition" && !definitions.has(node.identifier))
          definitions.set(node.identifier, node.url);
        if ("children" in node) collect(node);
      }
    }
    collect(tree);
    function visit(parent: Parent) {
      parent.children = parent.children.flatMap((node): RootContent[] => {
        // Never link code blocks, image descriptions, or text inside a link.
        if (node.type === "link" || node.type === "linkReference") {
          const url =
            node.type === "link" ? node.url : definitions.get(node.identifier);
          if (url && !/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(url)) {
            try {
              const alias = decodeURIComponent(url);
              if (references.has(alias))
                return [
                  {
                    ...node,
                    data: { hProperties: { "data-inline-reference": alias } },
                  },
                ];
            } catch {
              /* Malformed URL encoding is not a reference. */
            }
          }
          return [node];
        }
        if (["code", "html", "image", "imageReference"].includes(node.type))
          return [node];
        if (node.type === "inlineCode")
          return [references.has(node.value) ? link(node.value, node) : node];
        if (node.type === "text") {
          const result: RootContent[] = [];
          let offset = 0;
          for (const match of node.value.matchAll(pattern)) {
            if (match.index > offset)
              result.push({
                type: "text",
                value: node.value.slice(offset, match.index),
              });
            result.push(link(match[0], { type: "text", value: match[0] }));
            offset = match.index + match[0].length;
          }
          if (offset < node.value.length)
            result.push({ type: "text", value: node.value.slice(offset) });
          return result;
        }
        if ("children" in node) visit(node);
        return [node];
      });
    }
    visit(tree);
  };
}

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

// Stable component identities keep the actual opener mounted when preview state
// or a snapshot changes. The reference context updates callbacks without remounts.
const components: Components = {
  pre: ({ children: content }) => <>{content}</>,
  code: ({
    className: codeClassName,
    children: content,
    node: _node,
    ...props
  }) => {
    const value = String(content).replace(/\n$/, "");
    const language = codeClassName?.match(/language-(\w+)/)?.[1];
    if (!language && !value.includes("\n")) {
      return (
        <code className={codeClassName} {...props}>
          {content}
        </code>
      );
    }
    return (
      <CodeBlock
        aria-label={language ? `${language} code` : "Code block"}
        value={value}
      />
    );
  },
  a: function ReferenceLink({ href, children: content, node, ...props }) {
    const references = useContext(ReferenceContext);
    const alias = node?.properties["data-inline-reference"];
    const reference =
      typeof alias === "string" ? references?.get(alias) : undefined;
    if (reference)
      return (
        <Button
          type="button"
          variant="ghost"
          className="ai-markdown-reference"
          title={reference.label}
          aria-label={reference.label}
          onClick={(event) => reference.onOpen(event.currentTarget)}
        >
          {content}
        </Button>
      );
    const hrefValue = safeHref(href);
    if (!hrefValue) return <span>{content}</span>;
    // An unresolved path in a reference scope is not a web target.
    if (references && !/^(?:[a-z][a-z\d+.-]*:|\/\/|#)/i.test(hrefValue))
      return <span>{content}</span>;
    return (
      <a {...props} href={hrefValue} target="_blank" rel="noreferrer noopener">
        {content}
      </a>
    );
  },
};

export function Markdown({
  className,
  children,
  references,
}: {
  className?: string;
  children: string;
  references?: ReadonlyMap<string, MarkdownReference>;
}) {
  return (
    <div className={className ? `ai-markdown ${className}` : "ai-markdown"}>
      <ReferenceContext.Provider value={references}>
        <ReactMarkdown
          skipHtml
          remarkPlugins={
            references?.size
              ? [remarkGfm, referencePlugin(references)]
              : [remarkGfm]
          }
          components={components}
        >
          {children}
        </ReactMarkdown>
      </ReferenceContext.Provider>
    </div>
  );
}

export type MarkdownProps = ComponentPropsWithoutRef<typeof Markdown>;
