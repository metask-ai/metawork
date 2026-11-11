import type { WorkspaceDirectory } from "../bridge/contracts.ts";

export type WorkspaceFileLinkUnavailableReason =
  "outside_workspace" | "workspace_unavailable" | "unsupported_path";

export type WorkspaceFileLink =
  | { kind: "path"; path: string }
  | { kind: "unavailable"; reason: WorkspaceFileLinkUnavailableReason };

const outside = { kind: "unavailable", reason: "outside_workspace" } as const;
const unsupported = {
  kind: "unavailable",
  reason: "unsupported_path",
} as const;
const drivePath = /^[A-Za-z]:[\\/]/;

function decode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    // Browsers keep malformed escapes literally; so does a local file name.
    return value;
  }
}

// An explicit Markdown destination is a URL naming a local file. This maps it
// to the Workspace-relative form accepted by `metawork.files.previewWorkspace`
// without touching the filesystem; the Host independently re-checks Task,
// Workspace authority, containment and links before reading anything.
export function resolveWorkspaceFileLink(
  destination: string,
  workspaceRoot: string | null,
): WorkspaceFileLink {
  // A query or fragment addresses a location inside a resource, not its name.
  let target = decode(destination.replace(/[?#][\s\S]*$/, ""));
  if (/^file:/i.test(target)) {
    const local = /^file:\/\/(?:localhost)?(\/[\s\S]*)$/i.exec(target);
    if (!local) return unsupported;
    target = local[1].replace(/^\/(?=[A-Za-z]:[\\/])/, "");
  }
  if (/^~(?:[\\/]|$)/.test(target)) return unsupported;
  const windowsRoot = workspaceRoot !== null && drivePath.test(workspaceRoot);
  const separator = windowsRoot ? /[\\/]/ : "/";
  const absolute = target.startsWith("/") || drivePath.test(target);
  const segments = target.split(separator);
  if (absolute && segments[0] === "") segments.shift();
  const parts: string[] = [];
  for (const segment of segments) {
    if (segment === "") return unsupported;
    if (segment === ".") continue;
    if (segment === "..") {
      if (!parts.length) return outside;
      parts.pop();
    } else parts.push(segment);
  }
  let relative = parts;
  if (absolute) {
    if (!workspaceRoot)
      return { kind: "unavailable", reason: "workspace_unavailable" };
    const root = workspaceRoot.split(separator).filter(Boolean);
    const same = (left: string, right: string) =>
      windowsRoot ? left.toLowerCase() === right.toLowerCase() : left === right;
    if (
      parts.length < root.length ||
      root.some((segment, index) => !same(segment, parts[index]))
    )
      return outside;
    relative = parts.slice(root.length);
  }
  // Match the Host's Workspace path acceptance instead of offering a link
  // that can only be rejected after the user activates it.
  if (
    !relative.length ||
    relative.length > 64 ||
    relative.some((segment) => /[\u0000-\u001f\u007f\\:]/.test(segment))
  )
    return unsupported;
  const path = relative.join("/");
  if (new TextEncoder().encode(path).length > 4096) return unsupported;
  return { kind: "path", path };
}

export function workspaceFileParent(path: string): {
  directory: string;
  name: string;
} {
  const index = path.lastIndexOf("/");
  return {
    directory: index < 0 ? "" : path.slice(0, index),
    name: path.slice(index + 1),
  };
}

const nameKey = (name: string) => name.normalize("NFC").toLowerCase();

// Decides from one Host directory listing whether a regular file named `name`
// can exist for preview. Only a complete listing can prove absence; macOS and
// Windows volumes usually resolve case and Unicode normalization differences.
export function workspaceFilePresence(
  directory: WorkspaceDirectory,
  name: string,
): "present" | "missing" | "unknown" {
  if (directory.state === "missing" || directory.state === "restricted")
    return "missing";
  if (directory.state !== "ready") return "unknown";
  const entry =
    directory.entries.find((item) => item.name === name) ??
    directory.entries.find((item) => nameKey(item.name) === nameKey(name));
  if (entry) return entry.kind === "file" ? "present" : "missing";
  // Credential-named entries are omitted, but the Host rejects those paths too.
  return directory.truncated ? "unknown" : "missing";
}
