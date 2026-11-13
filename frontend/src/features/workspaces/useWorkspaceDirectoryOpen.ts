import { useState } from "react";
import type {
  WorkspaceOpenFailureReason,
  WorkspaceOpenResult,
  WorkspaceView,
} from "../../bridge/contracts.ts";

/** Host failure reasons, plus a request that produced no Host result. */
export type WorkspaceOpenFailure =
  WorkspaceOpenFailureReason | "request_failed";

export function useWorkspaceDirectoryOpen(
  workspace: WorkspaceView | undefined,
  onOpen: (() => Promise<WorkspaceOpenResult>) | undefined,
  disabled: boolean,
) {
  const [opening, setOpening] = useState(false);
  const [openFailure, setOpenFailure] = useState<WorkspaceOpenFailure | null>(
    null,
  );
  const cannotOpen =
    disabled ||
    opening ||
    !onOpen ||
    workspace?.kind !== "manual" ||
    workspace.projectRemoved ||
    workspace.redacted ||
    workspace.authorization !== "available";

  async function openDirectory() {
    if (cannotOpen || !onOpen) return;
    setOpening(true);
    setOpenFailure(null);
    try {
      const result = await onOpen();
      setOpenFailure(result.opened ? null : result.reason);
    } catch {
      setOpenFailure("request_failed");
    } finally {
      setOpening(false);
    }
  }

  return {
    cannotOpen,
    openDirectory,
    openFailure,
    // Dismissal only hides the notice; it never touches the project or disk.
    dismissOpenFailure: () => setOpenFailure(null),
  };
}
