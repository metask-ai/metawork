export function desktopPlatform(
  platform = typeof navigator === "undefined" ? "" : navigator.platform,
): "macos" | "windows" | "linux" {
  if (/Mac|iPhone|iPad|iPod/i.test(platform)) return "macos";
  if (/Win/i.test(platform)) return "windows";
  return "linux";
}

export function isInputMethodKey(
  event: { isComposing: boolean; keyCode: number },
  composing = false,
): boolean {
  // WebKit can deliver the confirming key after compositionend.
  return composing || event.isComposing || event.keyCode === 229;
}
