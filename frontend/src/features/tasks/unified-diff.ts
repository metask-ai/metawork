export type UnifiedDiffLineRow = {
  kind: "context" | "addition" | "deletion";
  text: string;
  oldLine: number | null;
  newLine: number | null;
};

export type UnifiedDiffRow =
  | UnifiedDiffLineRow
  | { kind: "metadata"; text: string }
  | { kind: "raw"; text: string }
  | { kind: "no-newline"; text: string }
  | {
      kind: "hunk";
      text: string;
      oldStart: number;
      newStart: number;
    }
  | { kind: "gap"; count: number };

type HunkHeader = {
  text: string;
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
};

type ParsedHunkLine = {
  kind: "context" | "addition" | "deletion" | "no-newline" | "raw";
  text: string;
};

const hunkHeaderPattern = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$/;

function parseHunkHeader(text: string): HunkHeader | null {
  const match = hunkHeaderPattern.exec(text);
  if (!match) return null;
  const header = {
    text,
    oldStart: Number(match[1]),
    oldCount: match[2] === undefined ? 1 : Number(match[2]),
    newStart: Number(match[3]),
    newCount: match[4] === undefined ? 1 : Number(match[4]),
  };
  return [
    header.oldStart,
    header.oldCount,
    header.newStart,
    header.newCount,
  ].every(Number.isSafeInteger)
    ? header
    : null;
}

function parseHunkLine(text: string): ParsedHunkLine {
  if (text.startsWith("\\ No newline at end of file"))
    return { kind: "no-newline", text };
  if (text.startsWith(" ")) return { kind: "context", text };
  if (text.startsWith("+")) return { kind: "addition", text };
  if (text.startsWith("-")) return { kind: "deletion", text };
  return { kind: "raw", text };
}

function metadataLine(text: string): boolean {
  return (
    text.startsWith("diff --git ") ||
    text.startsWith("index ") ||
    text.startsWith("--- ") ||
    text.startsWith("+++ ") ||
    text.startsWith("new file mode ") ||
    text.startsWith("deleted file mode ") ||
    text.startsWith("old mode ") ||
    text.startsWith("new mode ") ||
    text.startsWith("similarity index ") ||
    text.startsWith("dissimilarity index ") ||
    text.startsWith("rename from ") ||
    text.startsWith("rename to ") ||
    text.startsWith("copy from ") ||
    text.startsWith("copy to ") ||
    text.startsWith("Binary files ") ||
    text.startsWith("GIT binary patch")
  );
}

function provenGap(
  previousEnd: { old: number; new: number } | null | undefined,
  header: HunkHeader,
): number {
  if (previousEnd === null) return 0;
  const oldGap = header.oldStart - (previousEnd?.old ?? 1);
  const newGap = header.newStart - (previousEnd?.new ?? 1);
  return oldGap > 0 && oldGap === newGap ? oldGap : 0;
}

function rawHunk(
  header: HunkHeader,
  lines: ParsedHunkLine[],
): { rows: UnifiedDiffRow[]; end: null } {
  return {
    rows: [
      { kind: "raw", text: header.text },
      ...lines.map((line) => ({ kind: "raw" as const, text: line.text })),
    ],
    end: null,
  };
}

function renderHunk(
  header: HunkHeader,
  lines: ParsedHunkLine[],
  previousEnd: { old: number; new: number } | null | undefined,
): { rows: UnifiedDiffRow[]; end: { old: number; new: number } | null } {
  let oldConsumed = 0;
  let newConsumed = 0;
  let oldLine = header.oldStart;
  let newLine = header.newStart;
  const parsed: UnifiedDiffRow[] = [];

  for (const line of lines) {
    switch (line.kind) {
      case "context":
        if (oldConsumed >= header.oldCount || newConsumed >= header.newCount)
          return rawHunk(header, lines);
        parsed.push({
          kind: "context",
          text: line.text,
          oldLine,
          newLine,
        });
        oldConsumed += 1;
        newConsumed += 1;
        oldLine += 1;
        newLine += 1;
        break;
      case "deletion":
        if (oldConsumed >= header.oldCount) return rawHunk(header, lines);
        parsed.push({
          kind: "deletion",
          text: line.text,
          oldLine,
          newLine: null,
        });
        oldConsumed += 1;
        oldLine += 1;
        break;
      case "addition":
        if (newConsumed >= header.newCount) return rawHunk(header, lines);
        parsed.push({
          kind: "addition",
          text: line.text,
          oldLine: null,
          newLine,
        });
        newConsumed += 1;
        newLine += 1;
        break;
      case "no-newline":
        parsed.push({ kind: "no-newline", text: line.text });
        break;
      case "raw":
        return rawHunk(header, lines);
    }
  }

  if (oldConsumed !== header.oldCount || newConsumed !== header.newCount)
    return rawHunk(header, lines);

  const gap = provenGap(previousEnd, header);
  return {
    rows: [
      ...(gap > 0 ? ([{ kind: "gap", count: gap }] as const) : []),
      {
        kind: "hunk",
        text: header.text,
        oldStart: header.oldStart,
        newStart: header.newStart,
      },
      ...parsed,
    ],
    end: {
      old: header.oldStart + header.oldCount,
      new: header.newStart + header.newCount,
    },
  };
}

export function parseUnifiedDiff(content: string): UnifiedDiffRow[] {
  if (!content) return [];
  const lines = content.split(/\r?\n/);
  if (lines.at(-1) === "") lines.pop();

  const rows: UnifiedDiffRow[] = [];
  let previousEnd: { old: number; new: number } | null | undefined;
  let header: HunkHeader | null = null;
  let hunkLines: ParsedHunkLine[] = [];

  const finishHunk = () => {
    if (!header) return;
    const rendered = renderHunk(header, hunkLines, previousEnd);
    rows.push(...rendered.rows);
    previousEnd = rendered.end;
    header = null;
    hunkLines = [];
  };

  for (const line of lines) {
    const nextHeader = parseHunkHeader(line);
    if (nextHeader) {
      finishHunk();
      header = nextHeader;
      continue;
    }
    if (header && hunkHeaderPattern.test(line)) {
      finishHunk();
      previousEnd = null;
      rows.push({ kind: "raw", text: line });
      continue;
    }
    if (header && line.startsWith("diff --git ")) {
      finishHunk();
      previousEnd = undefined;
      rows.push({ kind: "metadata", text: line });
      continue;
    }
    if (header) {
      hunkLines.push(parseHunkLine(line));
      continue;
    }
    rows.push({ kind: metadataLine(line) ? "metadata" : "raw", text: line });
  }
  finishHunk();
  return rows;
}
