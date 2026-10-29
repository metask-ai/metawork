export type ClipboardWriteMode = "rich" | "plain";

function browserClipboard(): Clipboard {
  if (typeof navigator === "undefined" || !navigator.clipboard)
    throw new Error("Clipboard API is unavailable");
  return navigator.clipboard;
}

function richClipboardUnavailable(clipboard: Clipboard): boolean {
  if (typeof ClipboardItem !== "function") return true;
  if (typeof clipboard.write !== "function") return true;
  if (typeof ClipboardItem.supports !== "function") return false;
  return (
    !ClipboardItem.supports("text/html") ||
    !ClipboardItem.supports("text/plain")
  );
}

function plainClipboardItemUnavailable(clipboard: Clipboard): boolean {
  if (typeof ClipboardItem !== "function") return true;
  if (typeof clipboard.write !== "function") return true;
  return (
    typeof ClipboardItem.supports === "function" &&
    !ClipboardItem.supports("text/plain")
  );
}

export async function writeRichClipboard(
  markdown: string,
  renderHtml: () => string | Promise<string>,
): Promise<ClipboardWriteMode> {
  const clipboard = browserClipboard();
  if (richClipboardUnavailable(clipboard)) {
    if (typeof clipboard.writeText !== "function")
      throw new Error("Clipboard text fallback is unavailable");
    await clipboard.writeText(markdown);
    return "plain";
  }

  const item = new ClipboardItem({
    "text/html": Promise.resolve()
      .then(renderHtml)
      .then((html) => new Blob([html], { type: "text/html" })),
    "text/plain": new Blob([markdown], { type: "text/plain" }),
  });
  await clipboard.write([item]);
  return "rich";
}

export async function writePlainClipboard(text: string): Promise<void> {
  const clipboard = browserClipboard();
  if (!plainClipboardItemUnavailable(clipboard)) {
    await clipboard.write([
      new ClipboardItem({
        "text/plain": new Blob([text], { type: "text/plain" }),
      }),
    ]);
    return;
  }
  if (typeof clipboard.writeText !== "function")
    throw new Error("Clipboard text API is unavailable");
  await clipboard.writeText(text);
}
