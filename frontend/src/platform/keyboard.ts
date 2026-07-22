export function primaryShortcutModifier(
  platform = typeof navigator === "undefined" ? "" : navigator.platform,
): "⌘" | "Ctrl+" {
  return /Mac|iPhone|iPad|iPod/i.test(platform) ? "⌘" : "Ctrl+";
}
