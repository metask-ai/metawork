export function primaryShortcutModifier(
  platform = typeof navigator === "undefined" ? "" : navigator.platform,
): "⌘" | "Ctrl+" {
  return /Mac|iPhone|iPad|iPod/i.test(platform) ? "⌘" : "Ctrl+";
}

export function desktopPlatform(
  platform = typeof navigator === "undefined" ? "" : navigator.platform,
): "macos" | "windows" | "linux" {
  if (/Mac|iPhone|iPad|iPod/i.test(platform)) return "macos";
  if (/Win/i.test(platform)) return "windows";
  return "linux";
}
