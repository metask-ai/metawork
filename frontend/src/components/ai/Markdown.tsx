import {
  createContext,
  memo,
  useCallback,
  useDeferredValue,
  useContext,
  useId,
  useLayoutEffect,
  useState,
  type ComponentPropsWithoutRef,
  type MouseEvent,
  type ReactNode,
} from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import rehypeKatex from "rehype-katex";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import type { Element, ElementContent, Root as HastRoot } from "hast";
import type {
  Code,
  InlineCode,
  Link,
  Nodes as MdastNodes,
  Paragraph,
  Parent,
  Root,
  RootContent,
  Text,
} from "mdast";

import { CodeBlock } from "./CodeBlock.tsx";
import { Button } from "../ui/button.tsx";
import {
  contextMenuProps,
  type ContextMenuEvent,
} from "../ui/context-menu-anchor.ts";
import { Tooltip } from "../ui/tooltip.tsx";

export type MarkdownReference = {
  label: string;
  onOpen: (opener: HTMLButtonElement) => void;
  /** Opens what else there is to do with it, where there is anything. */
  onMenu?: (event: ContextMenuEvent) => void;
};

// Product features resolve an explicit local Markdown destination (path or
// file URL) to an opener, or to an already-localized reason it cannot open.
export type MarkdownLocalLinks = (
  destination: string,
) => MarkdownReference | { unavailable: string };

const ReferenceContext = createContext<
  ReadonlyMap<string, MarkdownReference> | undefined
>(undefined);
const LocalLinkContext = createContext<MarkdownLocalLinks | undefined>(
  undefined,
);

export type MarkdownCodeCopy = {
  label: string;
  copiedLabel: string;
  failedLabel: string;
  onCopy: (value: string) => void | Promise<unknown>;
};

const CodeCopyContext = createContext<MarkdownCodeCopy | undefined>(undefined);
const InteractionContext = createContext(true);

export type MarkdownWebLink = {
  failedLabel: string;
  onOpen: (href: string) => Promise<boolean>;
};

const WebLinkContext = createContext<MarkdownWebLink | undefined>(undefined);

// A destination that names a local file rather than a web resource: a path, a
// file URL or a drive-letter path. Fragments and queries stay in-document.
function localDestination(url: string): boolean {
  return (
    /^(?:file:|[a-z]:[\\/])/i.test(url) ||
    !/^(?:[a-z][a-z\d+.-]*:|\/\/|[#?])/i.test(url)
  );
}

function decodeDestination(url: string): string {
  try {
    return decodeURIComponent(url);
  } catch {
    return url;
  }
}

function referencePlugin(
  references: ReadonlyMap<string, MarkdownReference>,
  localLinks: boolean,
) {
  const aliases = [...references.keys()]
    .filter(Boolean)
    .sort((a, b) => b.length - a.length);
  const escaped = aliases.map((alias) =>
    alias.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
  );
  const pattern = aliases.length
    ? new RegExp(
        `(?<![\\p{L}\\p{N}_./\\\\~:@%+-])(?:${escaped.join("|")})(?![\\p{L}\\p{N}_/\\\\~:@%+-]|\\.[\\p{L}\\p{N}_])`,
        "gu",
      )
    : null;
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
          // An explicit link keeps its target; the feature decides at render
          // time whether the current Workspace can open it.
          if (url && localLinks && localDestination(url))
            return [
              { ...node, data: { hProperties: { "data-local-link": url } } },
            ];
          return [node];
        }
        if (["code", "html", "image", "imageReference"].includes(node.type))
          return [node];
        if (node.type === "inlineCode")
          return [references.has(node.value) ? link(node.value, node) : node];
        if (node.type === "text") {
          if (!pattern) return [node];
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

// LaTeX math for the shared Markdown root. KaTeX renders to MathML only: the
// WebView lays the formula out, so the app ships no math font, no stylesheet
// and no inline `style`, and the release CSP (`style-src 'self'`, with no
// 'unsafe-inline') stays untouched.

// Whatever unified hands a transformer as the file: only its source matters.
type Source = { toString(): string };

type MdastParent = Extract<MdastNodes, { children: MdastNodes[] }>;
// The shapes a formula arrives in: `remark-math`'s flow and text nodes, and
// GitHub's other block spelling, ` ```math `, which `remark-math` does not
// parse at all -- it stays a fenced code node, which `rehype-katex` then
// recognizes by its `language-math` class. Holding all of them as one math
// node here is what keeps a single streaming guard, a single fallback and a
// single copy path for both spellings.
type MathNode = {
  type: "math" | "inlineMath" | "code";
  data?: Record<string, unknown>;
};

const katexOptions = {
  output: "mathml",
  // Model output is untrusted input. `\href`, `\url` and `\includegraphics`
  // stay unexpanded and render as their own visible source.
  trust: false,
  // Questionable-but-parseable constructs render instead of failing the
  // document; a genuinely unknown command still falls back to its source.
  strict: false,
  // A self-recursive `\def` is a denial-of-service reachable from every
  // source this renderer accepts. Real formulas expand a handful of times;
  // this bound stops a bomb in under a millisecond and reaches the same
  // visible-source fallback as any other unparseable input.
  maxExpand: 256,
} as const;

// The one spelling a formula is handed back in when it cannot be rendered,
// whichever of the two block spellings it was written in: by then the failure
// has come from the typesetting layer, which no longer carries the author's.
const delimiter = "$$";
const displayClass = ["language-math", "math-display"];
// Chromium does not make a `math` element itself a scroll container, so the
// wrapper KaTeX puts around a display formula carries the class the
// stylesheet scrolls. Marking it here keeps the rule off `:has`.
const blockMathClass = "ai-markdown-math-block";

function isMath(node: MdastNodes): node is MathNode & MdastNodes {
  return (
    node.type === "math" ||
    node.type === "inlineMath" ||
    (node.type === "code" && node.lang === "math")
  );
}

// The delimited source exactly as the document spells it. A parsed `value` is
// unusable for an unterminated block: micromark reads the opening line as the
// fence's meta and leaves the value empty, so the text would simply vanish.
function mathSource(document: string, node: MdastNodes): string | null {
  const start = node.position?.start.offset;
  const end = node.position?.end.offset;
  return start === undefined || end === undefined
    ? null
    : document.slice(start, end);
}

// What the document opened the formula with: a run of dollars, or the marker
// of the fence the ` ```math ` spelling opened.
function openingDelimiter(source: string): string {
  return /^[ \t]*(\$+|`{3,}|~{3,})/.exec(source)?.[1] ?? "";
}

// A finished formula carries its closing delimiter. An Assistant still
// streaming one has not written it yet, and neither has a user who typed a
// lone `$$` or opened a fence. A fence closes on a line of its own carrying at
// least as many markers as it opened with -- the rule micromark itself applies
// before it reports the block closed, so a shorter run is still mid-formula.
function terminated(source: string): boolean {
  const opening = openingDelimiter(source);
  if (opening === "") return false;
  const body = source.trimEnd();
  if (opening.startsWith("$"))
    return body.length >= opening.length * 2 && body.endsWith(opening);
  return new RegExp(`\\n[ \\t]*${opening[0]}{${opening.length},}[ \\t]*$`).test(
    body,
  );
}

function paragraph(value: string): Paragraph {
  return { type: "paragraph", children: [{ type: "text", value }] };
}

// What the reader sees while a formula is still arriving: the source as far as
// it has been typed. A fence keeps the shape it was written in, because it is
// multi-line by construction -- a paragraph would collapse the lines the
// author typed -- and because every other unclosed fence on this root already
// streams in as a code block.
function arriving(node: MathNode, source: string): Text | Paragraph | Code {
  if (node.type === "code") return { type: "code", value: source };
  if (node.type === "inlineMath") return { type: "text", value: source };
  return paragraph(source);
}

// What a rich-text copy carries. It is pasted back through someone else's
// Markdown reader, and only the dollar spelling survives that trip: `$$…$$`
// in a paragraph is read back as a formula, while a fence can only travel
// inside a code block, where every character is literal -- a nested fence
// included. So a fenced formula is handed over in the dollar spelling, the
// same normalization an unrenderable formula's fallback makes, and both
// spellings of one formula copy to the same bytes.
function copied(node: MathNode & MdastNodes, source: string): Text | Paragraph {
  if (node.type === "code") {
    // Closed only if the author has closed it, so copying a formula that is
    // still arriving does not hand over a finished one -- the same thing the
    // dollar spelling does on this root, and the same thing the reader sees.
    const close = terminated(source) ? `\n${delimiter}` : "";
    return paragraph(`${delimiter}\n${node.value}${close}`);
  }
  return node.type === "inlineMath"
    ? { type: "text", value: source }
    : paragraph(source);
}

// Every mdast parent holds plain content; the union of their child arrays is
// what TypeScript cannot splice directly.
function replaceChild(
  parent: MdastParent,
  index: number,
  node: MdastNodes,
): void {
  (parent.children as MdastNodes[]).splice(index, 1, node);
}

function visitMdast(
  parent: MdastParent,
  each: (node: MdastNodes, index: number, parent: MdastParent) => void,
): void {
  // Backwards, so replacing a node cannot shift one not yet visited.
  for (let index = parent.children.length - 1; index >= 0; index -= 1) {
    const node = parent.children[index];
    if (node === undefined) continue;
    if ("children" in node) visitMdast(node, each);
    each(node, index, parent);
  }
}

function eachMath(
  tree: Root,
  each: (
    node: MathNode & MdastNodes,
    source: string,
    index: number,
    parent: MdastParent,
  ) => void,
  file: Source,
): void {
  const document = String(file);
  visitMdast(tree, (node, index, parent) => {
    if (!isMath(node)) return;
    const source = mathSource(document, node);
    if (source !== null) each(node, source, index, parent);
  });
}

/// Runs after `remark-math`, on the one GFM tree. It introduces no second
/// parser: every decision reads the original source through the positions that
/// same parse recorded.
function remarkMathSource() {
  return (tree: Root, file: Source) => {
    eachMath(
      tree,
      (node, source, index, parent) => {
        if (!terminated(source)) {
          // Show what has arrived, verbatim, until the closing delimiter does.
          replaceChild(parent, index, arriving(node, source));
          return;
        }
        // A formula written as its own line is display math, which micromark
        // reports as inline when the closing run is on that same line. One
        // inside running text stays inline, so it does not break the line.
        if (
          node.type !== "inlineMath" ||
          openingDelimiter(source).length < 2 ||
          parent.type !== "paragraph" ||
          parent.children.length !== 1
        )
          return;
        const data = (node.data ?? {}) as Record<string, unknown>;
        const properties = (data.hProperties ?? {}) as Record<string, unknown>;
        node.data = {
          ...data,
          hProperties: { ...properties, className: displayClass },
        };
      },
      file,
    );
  };
}

/// Replaces every math node with its delimited source, for the rich-text
/// clipboard root. Pasted `$$…$$` stays usable somewhere else; pasted MathML
/// would not be.
function remarkMathAsSource() {
  return (tree: Root, file: Source) => {
    eachMath(
      tree,
      (node, source, index, parent) => {
        replaceChild(parent, index, copied(node, source));
      },
      file,
    );
  };
}

function classList(node: Element): string[] {
  const value = node.properties.className;
  return Array.isArray(value) ? value.map(String) : [];
}

function textOf(node: ElementContent): string {
  if (node.type === "text") return node.value;
  return node.type === "element" ? node.children.map(textOf).join("") : "";
}

function stripStyle(node: ElementContent): void {
  if (node.type !== "element") return;
  if ("style" in node.properties) delete node.properties.style;
  for (const child of node.children) stripStyle(child);
}

function visitHast(
  parent: Element | HastRoot,
  each: (
    node: ElementContent,
    index: number,
    parent: Element | HastRoot,
  ) => void,
): void {
  for (let index = parent.children.length - 1; index >= 0; index -= 1) {
    const node = parent.children[index];
    if (node === undefined) continue;
    if (node.type === "element") visitHast(node, each);
    each(node as ElementContent, index, parent);
  }
}

/// Runs after `rehype-katex`. KaTeX's MathML needs no CSS, but both its own
/// error span and rehype-katex's fallback carry an inline `style`, which the
/// release CSP blocks. Neither may reach the document, so a formula KaTeX
/// cannot render falls back to the delimited source it was written as.
function rehypeMathSafety() {
  return (tree: HastRoot) => {
    visitHast(tree, (node, index, parent) => {
      if (node.type !== "element") return;
      const classes = classList(node);
      if (classes.includes("katex-error")) {
        // What KaTeX was handed is the formula's LaTeX, and that is what comes
        // back, in one spelling whichever the author used. A fenced formula
        // reaches here through the generic code-block handler, which appends a
        // newline to a block's text; it is not part of the formula, so it is
        // not part of the source handed back either.
        const source = textOf(node).replace(/\n+$/, "");
        parent.children.splice(index, 1, {
          type: "text",
          value: `${delimiter}${source}${delimiter}`,
        });
        return;
      }
      if (!classes.some((name) => name.startsWith("katex"))) return;
      stripStyle(node);
      const display = node.children.some(
        (child) =>
          child.type === "element" &&
          child.tagName === "math" &&
          child.properties.display === "block",
      );
      if (display) node.properties.className = [...classes, blockMathClass];
    });
  };
}

function safeHref(href: string | undefined): string | null {
  if (!href) return null;
  if (href.startsWith("//")) return null;
  if (!href.includes(":")) return href;
  try {
    const url = new URL(href, "https://metawork.invalid");
    if (["http:", "https:", "mailto:"].includes(url.protocol)) return href;
  } catch {
    return null;
  }
  return null;
}

function WebLink({
  href,
  children,
  ...props
}: ComponentPropsWithoutRef<"a"> & { href: string }) {
  const webLink = useContext(WebLinkContext);
  const [failed, setFailed] = useState(false);
  const [opening, setOpening] = useState(false);
  const open = useCallback(
    (event: MouseEvent<HTMLAnchorElement>) => {
      event.preventDefault();
      if (!webLink || opening) return;
      setFailed(false);
      setOpening(true);
      void webLink
        .onOpen(href)
        .then((opened) => setFailed(!opened))
        .catch(() => setFailed(true))
        .finally(() => setOpening(false));
    },
    [href, opening, webLink],
  );

  if (!webLink)
    return (
      <a {...props} href={href} target="_blank" rel="noreferrer noopener">
        {children}
      </a>
    );

  return (
    <span className="ai-markdown-web-link">
      <a
        {...props}
        href={href}
        aria-busy={opening || undefined}
        onClick={open}
        onAuxClick={(event) => {
          if (event.button === 1) open(event);
        }}
      >
        {children}
      </a>
      {failed && (
        <span className="ai-markdown-link-error" role="alert">
          {webLink.failedLabel}
        </span>
      )}
    </span>
  );
}

// Keeps an explicit link target perceivable without presenting an action.
function UnavailableLocalLink({
  reason,
  target,
  children,
}: {
  reason: string;
  target: string;
  children: ReactNode;
}) {
  const description = useId();
  return (
    <Tooltip.Root>
      <Tooltip.Trigger
        render={
          <span
            role="link"
            aria-disabled="true"
            aria-describedby={description}
            tabIndex={0}
            className="ai-markdown-file-link-unavailable"
          />
        }
      >
        {children}
      </Tooltip.Trigger>
      <span id={description} hidden>
        {`${reason} ${target}`}
      </span>
      <Tooltip.Portal>
        <Tooltip.Positioner side="top">
          <Tooltip.Popup className="max-w-[min(28rem,calc(100vw-2rem))]">
            <span className="block">{reason}</span>
            <span className="block [overflow-wrap:anywhere]">{target}</span>
          </Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

// Stable component identities keep the actual opener mounted when preview state
// or a snapshot changes. The reference context updates callbacks without remounts.
const components: Components = {
  pre: ({ node }) => {
    const copy = useContext(CodeCopyContext);
    // The Markdown AST owns block/inline semantics, not line count or language.
    const code = node?.children[0];
    const value =
      code?.type === "element"
        ? code.children
            .filter((child) => child.type === "text")
            .map((child) => child.value)
            .join("")
        : "";
    const classes =
      code?.type === "element" ? String(code.properties.className ?? "") : "";
    const language = classes.match(/language-(\S+)/)?.[1];
    return (
      <CodeBlock
        aria-label={language ? `${language} code` : "Code block"}
        value={value.replace(/\n$/, "")}
        copy={copy}
      />
    );
  },
  code: ({ children, node: _node, ...props }) => (
    <code {...props}>{children}</code>
  ),
  a: function ReferenceLink({ href, children: content, node, ...props }) {
    const interactive = useContext(InteractionContext);
    const references = useContext(ReferenceContext);
    const localLinks = useContext(LocalLinkContext);
    if (!interactive) return <span>{content}</span>;
    const alias = node?.properties["data-inline-reference"];
    const destination = node?.properties["data-local-link"];
    const local =
      typeof destination === "string" ? localLinks?.(destination) : undefined;
    if (local && "unavailable" in local)
      return (
        <UnavailableLocalLink
          reason={local.unavailable}
          target={decodeDestination(String(destination))}
        >
          {content}
        </UnavailableLocalLink>
      );
    const reference =
      typeof alias === "string" ? references?.get(alias) : local;
    if (reference)
      return (
        <Button
          type="button"
          variant="ghost"
          className="ai-markdown-reference"
          title={reference.label}
          aria-label={reference.label}
          onClick={(event) => reference.onOpen(event.currentTarget)}
          {...contextMenuProps(reference.onMenu)}
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
      <WebLink {...props} href={hrefValue}>
        {content}
      </WebLink>
    );
  },
  img: ({ alt }) => <span>{alt}</span>,
};

function clipboardHref(href: string | undefined): string | null {
  const value = safeHref(href);
  return value && /^(?:https?:|mailto:)/i.test(value) ? value : null;
}

// Only `$$…$$` is a formula. Single-dollar text math would read ordinary
// prose such as "costs $5 and $7" as one, and swallow both amounts.
const mathSyntax: [typeof remarkMath, { singleDollarTextMath: false }] = [
  remarkMath,
  { singleDollarTextMath: false },
];

const clipboardComponents: Components = {
  a: ({ href, children }) => {
    const value = clipboardHref(href);
    return value ? <a href={value}>{children}</a> : <span>{children}</span>;
  },
  img: ({ alt }) => <span>{alt}</span>,
  input: ({ checked }) => <>{checked ? "[x]" : "[ ]"}</>,
  ul: ({ children }) => <ul>{children}</ul>,
  ol: ({ children }) => <ol>{children}</ol>,
  li: ({ children }) => <li>{children}</li>,
  code: ({ children }) => <code>{children}</code>,
  pre: ({ children }) => <pre>{children}</pre>,
};

export async function renderMarkdownForClipboard(
  markdown: string,
): Promise<string> {
  const { renderToStaticMarkup } = await import("react-dom/server");
  return renderToStaticMarkup(
    <ReactMarkdown
      skipHtml
      remarkPlugins={[remarkGfm, mathSyntax, remarkMathAsSource]}
      components={clipboardComponents}
    >
      {markdown}
    </ReactMarkdown>,
  );
}

const textResourceComponents: Components = {
  ...components,
  img: ({ alt }) => <span>{alt}</span>,
  a: ({ href, children, node: _node, ...props }) => {
    // Documents do not gain a relative-resource or app navigation capability.
    const value = safeHref(href);
    return value && /^https?:/i.test(value) ? (
      <WebLink {...props} href={value}>
        {children}
      </WebLink>
    ) : (
      <span>{children}</span>
    );
  },
};

type MarkdownBodyProps = {
  children: string;
  references?: ReadonlyMap<string, MarkdownReference>;
  referenceFingerprint: string;
  localLinks: boolean;
  textResourcesOnly: boolean;
};

const noReferences: ReadonlyMap<string, MarkdownReference> = new Map();

const MarkdownBody = memo(
  function MarkdownBody({
    children,
    references,
    localLinks,
    textResourcesOnly,
  }: MarkdownBodyProps) {
    return (
      <ReactMarkdown
        skipHtml
        remarkPlugins={[
          remarkGfm,
          mathSyntax,
          ...(references?.size || localLinks
            ? [referencePlugin(references ?? noReferences, localLinks)]
            : []),
          // Last: it reads the source the same parse recorded, so no earlier
          // plugin can have rewritten a formula's positions.
          remarkMathSource,
        ]}
        rehypePlugins={[[rehypeKatex, katexOptions], rehypeMathSafety]}
        components={textResourcesOnly ? textResourceComponents : components}
      >
        {children}
      </ReactMarkdown>
    );
  },
  (previous, next) =>
    previous.children === next.children &&
    previous.referenceFingerprint === next.referenceFingerprint &&
    previous.localLinks === next.localLinks &&
    previous.textResourcesOnly === next.textResourcesOnly,
);

export type MarkdownProps = Omit<
  ComponentPropsWithoutRef<"div">,
  "children"
> & {
  children: string;
  references?: ReadonlyMap<string, MarkdownReference>;
  localLinks?: MarkdownLocalLinks;
  textResourcesOnly?: boolean;
  codeCopy?: MarkdownCodeCopy;
  webLink?: MarkdownWebLink;
  interactive?: boolean;
  onStreamingCommit?: () => void;
  streaming?: boolean;
};

export function Markdown({
  className,
  children,
  references,
  localLinks,
  textResourcesOnly = false,
  codeCopy,
  webLink,
  interactive = true,
  onStreamingCommit,
  streaming = false,
  ...props
}: MarkdownProps) {
  const deferredChildren = useDeferredValue(children);
  const visibleChildren = streaming && children ? deferredChildren : children;
  const referenceFingerprint = references?.size
    ? JSON.stringify([...references.keys()].sort())
    : "";
  useLayoutEffect(() => {
    if (streaming) onStreamingCommit?.();
  }, [onStreamingCommit, streaming, visibleChildren]);
  return (
    <div
      className={className ? `ai-markdown ${className}` : "ai-markdown"}
      {...props}
    >
      <ReferenceContext.Provider value={references}>
        <LocalLinkContext.Provider value={localLinks}>
          <WebLinkContext.Provider value={webLink}>
            <CodeCopyContext.Provider value={codeCopy}>
              <InteractionContext.Provider value={interactive}>
                <MarkdownBody
                  references={references}
                  referenceFingerprint={referenceFingerprint}
                  localLinks={Boolean(localLinks)}
                  textResourcesOnly={textResourcesOnly}
                >
                  {visibleChildren}
                </MarkdownBody>
              </InteractionContext.Provider>
            </CodeCopyContext.Provider>
          </WebLinkContext.Provider>
        </LocalLinkContext.Provider>
      </ReferenceContext.Provider>
    </div>
  );
}
