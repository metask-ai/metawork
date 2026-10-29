import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

const MAX_CODE_UNITS = 65_536;
const MAX_LINES = 1_500;
const MAX_AST_NODES = 20_000;
const MAX_AST_DEPTH = 8;

const SPECIAL_FILENAMES = new Map<PreviewLanguage, readonly string[]>([
  ["docker", ["Dockerfile", "Containerfile"]],
  ["makefile", ["Makefile", "GNUmakefile"]],
  ["cmake", ["CMakeLists.txt"]],
  ["toml", ["Cargo.lock"]],
  ["ruby", ["Gemfile"]],
]);

const EXTENSION_LANGUAGES: Readonly<Record<string, PreviewLanguage>> = {
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  jsx: "jsx",
  ts: "typescript",
  mts: "typescript",
  cts: "typescript",
  tsx: "tsx",
  json: "json",
  jsonc: "json",
  zig: "zig",
  zon: "zig",
  py: "python",
  rs: "rust",
  go: "go",
  c: "c",
  h: "c",
  cc: "cpp",
  cpp: "cpp",
  cxx: "cpp",
  hpp: "cpp",
  cs: "csharp",
  java: "java",
  html: "markup",
  htm: "markup",
  xml: "markup",
  svg: "markup",
  css: "css",
  md: "markdown",
  markdown: "markdown",
  yaml: "yaml",
  yml: "yaml",
  toml: "toml",
  ini: "ini",
  cfg: "ini",
  conf: "ini",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  ps1: "powershell",
  psm1: "powershell",
  psd1: "powershell",
  sql: "sql",
  diff: "diff",
  patch: "diff",
  rb: "ruby",
};

type PreviewLanguage =
  | "bash"
  | "c"
  | "cmake"
  | "cpp"
  | "csharp"
  | "css"
  | "diff"
  | "docker"
  | "go"
  | "ini"
  | "java"
  | "javascript"
  | "json"
  | "jsx"
  | "makefile"
  | "markdown"
  | "markup"
  | "powershell"
  | "python"
  | "ruby"
  | "rust"
  | "sql"
  | "toml"
  | "tsx"
  | "typescript"
  | "yaml"
  | "zig";

type ValidHighlightNode =
  | { type: "text"; value: string }
  | {
      type: "element";
      className: readonly string[];
      children: readonly ValidHighlightNode[];
    };

type HighlighterModule = {
  highlightSource(content: string, language: string): unknown;
};

type LoadHighlighter = () => Promise<HighlighterModule>;

const loadDefaultHighlighter: LoadHighlighter = () =>
  import("./syntax-highlight.ts");

function basename(displayPath: string): string {
  return displayPath.split(/[\\/]/).at(-1) ?? "";
}

function resolveShebang(content: string): PreviewLanguage | null {
  const firstLine = content.slice(0, 512).split(/\r\n?|\n/, 1)[0];
  if (!firstLine.startsWith("#!")) return null;

  const words = firstLine.slice(2).trim().split(/\s+/);
  let commandIndex = 0;
  const firstCommand = basename(words[0] ?? "");
  if (firstCommand === "env") {
    commandIndex = 1;
    while (words[commandIndex]?.startsWith("-")) commandIndex += 1;
  }
  const command = basename(words[commandIndex] ?? "").toLowerCase();
  if (["node", "deno", "bun"].includes(command)) return "javascript";
  if (command === "python" || command === "python3") return "python";
  if (["sh", "bash", "zsh"].includes(command)) return "bash";
  if (command === "pwsh" || command === "powershell") return "powershell";
  return command === "ruby" ? "ruby" : null;
}

export function resolvePreviewLanguage(
  displayPath: string,
  content: string,
): PreviewLanguage | null {
  const file = basename(displayPath);
  for (const [language, filenames] of SPECIAL_FILENAMES) {
    if (filenames.includes(file)) return language;
  }

  const extensionIndex = file.lastIndexOf(".");
  if (extensionIndex > 0 && extensionIndex < file.length - 1) {
    const language =
      EXTENSION_LANGUAGES[file.slice(extensionIndex + 1).toLowerCase()];
    if (language) return language;
  }

  return resolveShebang(content);
}

export function countSourceLines(content: string): number {
  let lines = 1;
  for (let index = 0; index < content.length; index += 1) {
    const codeUnit = content.charCodeAt(index);
    if (
      codeUnit === 10 ||
      (codeUnit === 13 && content.charCodeAt(index + 1) !== 10)
    ) {
      lines += 1;
    }
  }
  return lines;
}

export function isWithinHighlightBudget(content: string): boolean {
  return (
    content.length > 0 &&
    content.length <= MAX_CODE_UNITS &&
    countSourceLines(content) <= MAX_LINES
  );
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function hasOnlyKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}

export function validateHighlightTree(
  value: unknown,
  content: string,
): readonly ValidHighlightNode[] | null {
  if (
    !isObject(value) ||
    value.type !== "root" ||
    !Array.isArray(value.children) ||
    !hasOnlyKeys(value, ["type", "children"])
  ) {
    return null;
  }

  let nodeCount = 1;
  const textParts: string[] = [];
  const validateChildren = (
    children: readonly unknown[],
    depth: number,
  ): readonly ValidHighlightNode[] | null => {
    if (depth > MAX_AST_DEPTH) return null;
    const validated: ValidHighlightNode[] = [];
    for (const child of children) {
      nodeCount += 1;
      if (nodeCount > MAX_AST_NODES || !isObject(child)) return null;
      if (
        child.type === "text" &&
        typeof child.value === "string" &&
        hasOnlyKeys(child, ["type", "value"])
      ) {
        textParts.push(child.value);
        validated.push({ type: "text", value: child.value });
        continue;
      }
      if (
        child.type !== "element" ||
        child.tagName !== "span" ||
        !Array.isArray(child.children) ||
        !isObject(child.properties) ||
        !hasOnlyKeys(child, ["type", "tagName", "properties", "children"]) ||
        !hasOnlyKeys(child.properties, ["className"]) ||
        !Array.isArray(child.properties.className) ||
        !child.properties.className.every(
          (name) => typeof name === "string" && /^[a-z][a-z0-9-]*$/.test(name),
        )
      ) {
        return null;
      }
      const validatedChildren = validateChildren(child.children, depth + 1);
      if (!validatedChildren) return null;
      validated.push({
        type: "element",
        className: child.properties.className,
        children: validatedChildren,
      });
    }
    return validated;
  };

  const validated = validateChildren(value.children, 1);
  return validated && textParts.join("") === content ? validated : null;
}

function renderHighlightNode(node: ValidHighlightNode, key: string): ReactNode {
  if (node.type === "text") return node.value;
  return (
    <span key={key} className={node.className.join(" ")}>
      {node.children.map((child, index) =>
        renderHighlightNode(child, `${key}.${index}`),
      )}
    </span>
  );
}

export function HighlightedSource({
  displayPath,
  content,
  loadHighlighter = loadDefaultHighlighter,
  scrollTop,
  onScrollTopChange,
}: {
  displayPath: string;
  content: string;
  loadHighlighter?: LoadHighlighter;
  scrollTop?: number;
  onScrollTopChange?: (scrollTop: number) => void;
}) {
  const scrollContainer = useRef<HTMLDivElement | null>(null);
  const language = resolvePreviewLanguage(displayPath, content);
  const highlightIdentity = useMemo(
    () => Symbol("source-highlight"),
    [displayPath, content],
  );
  const [highlighted, setHighlighted] = useState<{
    identity: symbol;
    nodes: readonly ValidHighlightNode[];
  } | null>(null);

  useEffect(() => {
    let cancelled = false;
    setHighlighted(null);
    if (!language || !isWithinHighlightBudget(content)) return undefined;

    void loadHighlighter()
      .then((highlighter) => {
        if (cancelled) return;
        const nodes = validateHighlightTree(
          highlighter.highlightSource(content, language),
          content,
        );
        if (!cancelled && nodes) {
          setHighlighted({ identity: highlightIdentity, nodes });
        }
      })
      .catch(() => undefined);

    return () => {
      cancelled = true;
    };
  }, [content, highlightIdentity, language, loadHighlighter]);

  const nodes =
    highlighted?.identity === highlightIdentity ? highlighted.nodes : null;
  const lineNumbers = useMemo(
    () =>
      Array.from(
        { length: countSourceLines(content) },
        (_, index) => index + 1,
      ).join("\n"),
    [content],
  );

  useLayoutEffect(() => {
    if (scrollTop === undefined || !scrollContainer.current) return;
    scrollContainer.current.scrollTop = scrollTop;
  }, [content, displayPath, scrollTop]);

  return (
    <div
      ref={scrollContainer}
      className="task-panel-code focus-ring"
      tabIndex={0}
      onScroll={(event) => onScrollTopChange?.(event.currentTarget.scrollTop)}
    >
      <div className="task-panel-code-layout">
        <pre className="task-panel-code-gutter" aria-hidden="true">
          {lineNumbers}
        </pre>
        <pre className="task-panel-code-source">
          <code className={language ? `language-${language}` : undefined}>
            {nodes
              ? nodes.map((node, index) =>
                  renderHighlightNode(node, String(index)),
                )
              : content}
          </code>
        </pre>
      </div>
    </div>
  );
}
