import type { InlineCode, Link, Parent, Root, RootContent, Text } from "mdast";

// A destination that names a local file rather than a web resource: a path, a
// file URL or a drive-letter path. Fragments and queries stay in-document.
function localDestination(url: string): boolean {
  return (
    /^(?:file:|[a-z]:[\\/])/i.test(url) ||
    !/^(?:[a-z][a-z\d+.-]*:|\/\/|[#?])/i.test(url)
  );
}

export function referencePlugin(
  references: ReadonlyMap<string, unknown>,
  localLinks: boolean,
  onFile?: (kind: "reference" | "workspace", value: string) => void,
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
    onFile?.("reference", alias);
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
              if (references.has(alias)) {
                onFile?.("reference", alias);
                return [
                  {
                    ...node,
                    data: { hProperties: { "data-inline-reference": alias } },
                  },
                ];
              }
            } catch {
              /* Malformed URL encoding is not a reference. */
            }
          }
          // An explicit link keeps its target; the feature decides at render
          // time whether the current Workspace can open it.
          if (url && localLinks && localDestination(url)) {
            onFile?.("workspace", url);
            return [
              { ...node, data: { hProperties: { "data-local-link": url } } },
            ];
          }
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
