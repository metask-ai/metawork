import { useState } from "react";
import type { WorkspaceView } from "../../bridge/contracts.ts";

export function useWorkspaceDirectoryOpen(
  workspace: WorkspaceView | undefined,
  onOpen: (() => Promise<{ opened: boolean }>) | undefined,
  disabled: boolean,
) {
  const [state, setState] = useState<"idle" | "opening" | "failed">("idle");
  const cannotOpen =
    disabled ||
    state === "opening" ||
    !onOpen ||
    workspace?.kind !== "manual" ||
    workspace.projectRemoved ||
    workspace.redacted ||
    workspace.authorization !== "available";

  async function openDirectory() {
    if (cannotOpen || !onOpen) return;
    setState("opening");
    try {
      setState((await onOpen()).opened ? "idle" : "failed");
    } catch {
      setState("failed");
    }
  }

  return { cannotOpen, openDirectory, openFailed: state === "failed" };
}
