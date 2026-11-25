import type {
  FileActionHandler,
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
export type FileReferenceResult =
  "edit_prepared" | "cancelled" | "edit_unavailable";

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

export async function performFileMenuAction(
  file: MenuFile,
  action: FileMenuAction,
  signal: AbortSignal,
  runAction: FileActionHandler,
  reference: (
    target: FileTarget,
    path: string,
    signal: AbortSignal,
  ) => Promise<FileReferenceResult>,
): Promise<FileMenuOutcome> {
  const target = menuFileTarget(file);
  try {
    const state = await runAction(
      target,
      action === "reference" ? "check_current" : action,
      signal,
    );
    if (action === "reference" && state === "ready")
      return signal.aborted
        ? null
        : fileMenuOutcome(await reference(target, file.displayPath, signal));
    return fileMenuOutcome(state, action);
  } catch {
    if (action === "save") return { message: "outputs.state.save_unknown" };
    return signal.aborted ? null : { message: "outputs.state.failed" };
  }
}

export function fileMenuOutcome(
  state: FileActionState | FileReferenceResult,
  action?: FileMenuAction,
): FileMenuOutcome {
  switch (state) {
    case "opened":
    case "revealed":
    case "saved":
    case "path_copied":
    case "edit_prepared":
    case "cancelled":
      return null;
    case "changed":
      return {
        message:
          action === "check"
            ? "outputs.state.changed"
            : "outputs.state.file_changed",
      };
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
