import type {
  FileActionState,
  FileDescriptionResult,
  FilePreview,
  FilePreviewLoadOptions,
  FileTarget,
  TaskView,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import type {
  FileMenuAction,
  FileMenuOutcome,
  MenuFile,
} from "../../components/FileMenu.tsx";
import type { MessageId } from "../../i18n/context.ts";
import { findRunFileReference } from "../../workbench/run-file-references.ts";
import type { FileReferenceResult } from "./RunOutputs.tsx";

export type FilePreviewLoader = (
  target: FileTarget,
  options?: FilePreviewLoadOptions,
) => Promise<FilePreview>;

export type FileDescriber = (
  target: FileTarget,
  options?: FilePreviewLoadOptions,
) => Promise<FileDescriptionResult>;

/** The menu of one file, whose target only the handler above it reads back. */
export function menuFile(
  target: FileTarget,
  displayPath: string,
  facts: Pick<MenuFile, "available" | "openable"> = {},
): MenuFile {
  return { target, displayPath, ...facts };
}

export function menuFileTarget(file: MenuFile): FileTarget {
  return file.target as FileTarget;
}

/**
 * What to say about a finished action. A file that was opened or shown in its
 * folder answers for itself; the rest is said where it was asked.
 */
export function fileMenuOutcome(
  action: FileMenuAction,
  state: FileActionState | FileReferenceResult,
): FileMenuOutcome {
  switch (state) {
    case "opened":
    case "revealed":
      return null;
    case "path_copied":
      return { message: "outputs.state.path_copied", brief: true };
    // Nothing in the menu compares with a delivery.
    case "changed":
      return { message: "outputs.state.file_changed" };
    default:
      return { message: `outputs.state.${state}` };
  }
}

/** Whether the interface still shows the file a target names. */
export function fileTargetShown(
  task: TaskView,
  workspaces: readonly WorkspaceView[],
  target: FileTarget,
): boolean {
  if (task.id !== target.taskId) return false;
  if (target.kind === "workspace")
    return (
      task.workspaceId === target.workspaceId &&
      workspaces.some(
        (workspace) =>
          workspace.id === target.workspaceId &&
          workspace.epoch === target.workspaceEpoch,
      )
    );
  const run = task.runs.find((candidate) => candidate.id === target.runId);
  if (target.kind === "reference")
    return Boolean(run && findRunFileReference(run, target.fileReferenceId));
  const output =
    run?.outputs.find((record) => record.id === target.outputId) ??
    task.conversationOutputs?.find(
      (record) =>
        record.id === target.outputId && record.runId === target.runId,
    );
  return Boolean(output && !output.redacted);
}

/** Why a file has no description to show. */
export function descriptionFailure(
  state: Exclude<FileDescriptionResult["state"], "ready">,
): MessageId {
  return `file_card.state.${state}`;
}

/** The outcomes that say the file is not shown in place, whatever it is. */
export function previewNotInline(preview: FilePreview): boolean {
  return (
    preview.state === "unsupported" ||
    (preview.state === "ready" && !preview.image && !preview.video)
  );
}
