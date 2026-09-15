import type { RunView } from "../../bridge/contracts.ts";
import { renderMarkdownForClipboard } from "../../components/ai/Markdown.tsx";
import {
  writePlainClipboard,
  writeRichClipboard,
} from "../../platform/clipboard.ts";

export function responseCopyEligible(
  run: Pick<RunView, "terminal" | "output">,
): boolean {
  return (
    run.terminal !== null &&
    run.output.responseKind !== null &&
    run.output.response.length > 0
  );
}

export function latestCopyableResponseId(
  runs: readonly Pick<RunView, "id" | "terminal" | "output">[],
): string | null {
  return runs.filter(responseCopyEligible).at(-1)?.id ?? null;
}

export async function copyResponseMarkdown(markdown: string): Promise<void> {
  await writeRichClipboard(markdown, () =>
    renderMarkdownForClipboard(markdown),
  );
}

export async function copyCodeText(value: string): Promise<void> {
  await writePlainClipboard(value);
}
