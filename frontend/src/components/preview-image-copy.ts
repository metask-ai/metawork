import {
  imageClipboardAvailable,
  writeImageClipboard,
} from "../platform/clipboard.ts";
import type { FileMenuOutcome } from "./FileMenu.tsx";
import type { PreviewImageResource } from "./PreviewImageView.tsx";

/** An image that also knows whether what it was checked under still holds. */
export interface CopyableImage extends PreviewImageResource {
  current: () => boolean;
}

/**
 * Copies a displayed image: what the Host checked and handed over, as the
 * WebView decodes it, in its own resolution. Undefined where the runtime has
 * no such clipboard, null while there is no decoded image.
 */
export function previewImageCopy(
  image: CopyableImage | null | undefined,
  decoded: boolean,
): ((signal: AbortSignal) => Promise<FileMenuOutcome>) | null | undefined {
  if (!imageClipboardAvailable()) return undefined;
  if (!image || !decoded) return null;
  return (signal) => copyPreviewImage(image, signal);
}

async function copyPreviewImage(
  image: CopyableImage,
  signal: AbortSignal,
): Promise<FileMenuOutcome> {
  // Its release once it is out of view does not take the pixels back; a change
  // of what it was checked under does.
  const source = image.src;
  try {
    await writeImageClipboard(async () => {
      const png = await encodePng(source);
      signal.throwIfAborted();
      if (!image.current())
        throw new Error("The image is not authorized any more");
      return png;
    });
    return null;
  } catch {
    if (signal.aborted) return null;
    return {
      message: image.current()
        ? "outputs.state.copy_failed"
        : "outputs.state.stale_security",
    };
  }
}

async function encodePng(source: string): Promise<Blob> {
  const element = new Image();
  element.src = source;
  await element.decode();
  const canvas = document.createElement("canvas");
  try {
    canvas.width = element.naturalWidth;
    canvas.height = element.naturalHeight;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("No canvas to encode the image on");
    context.drawImage(element, 0, 0);
    return await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        (blob) =>
          blob ? resolve(blob) : reject(new Error("The image is not encoded")),
        "image/png",
      ),
    );
  } finally {
    // Its pixels are freed here and not whenever the element is collected.
    canvas.width = 0;
    canvas.height = 0;
  }
}
