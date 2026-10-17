import type { TaskView } from "../bridge/contracts.ts";

export type TaskModelSelectionPolicy = {
  showsSelector: boolean;
  selectable: boolean;
  pending: boolean;
};

export function taskModelSelectionPolicy(
  task: TaskView | null,
): TaskModelSelectionPolicy {
  if (task?.modelIntent?.state === "outcome_unknown")
    return { showsSelector: true, selectable: false, pending: true };
  switch (task?.modelSelectionAvailability) {
    case "available":
      return { showsSelector: true, selectable: true, pending: false };
    case "catalog_loading":
    case "execution_replacing":
      return { showsSelector: true, selectable: false, pending: true };
    case "catalog_unavailable":
      return { showsSelector: true, selectable: false, pending: false };
    case "runtime_detached":
    case "unsupported_source":
    case "authority_changed":
    default:
      return { showsSelector: false, selectable: false, pending: false };
  }
}
