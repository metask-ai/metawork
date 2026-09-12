import type { TaskView } from "../bridge/contracts.ts";

export type CompletionAcknowledgement = {
  taskId: string;
  runId: string;
  key: string;
};

export function completionAcknowledgementCandidate({
  task,
  workbenchRoute,
  settingsOpen,
  searchOpen,
  modalOpen,
  taskStageExposed,
  documentAttention,
  bridgeAvailable,
}: {
  task: TaskView | null;
  workbenchRoute: boolean;
  settingsOpen: boolean;
  searchOpen: boolean;
  modalOpen: boolean;
  taskStageExposed: boolean;
  documentAttention: boolean;
  bridgeAvailable: boolean;
}): CompletionAcknowledgement | null {
  if (
    task === null ||
    task.unreadCompletionRunId === null ||
    !workbenchRoute ||
    settingsOpen ||
    searchOpen ||
    modalOpen ||
    !taskStageExposed ||
    !documentAttention ||
    !bridgeAvailable
  )
    return null;
  return {
    taskId: task.id,
    runId: task.unreadCompletionRunId,
    key: `${task.id}:${task.unreadCompletionRunId}`,
  };
}

export function completionReminderSuppressionTaskId(
  acknowledgement: CompletionAcknowledgement | null,
  failedKey: string | null,
) {
  return acknowledgement !== null && acknowledgement.key !== failedKey
    ? acknowledgement.taskId
    : null;
}
