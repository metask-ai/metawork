import { readyModelOptions } from "./new-task-model-selection.ts";
import type { ModelsView, ModelRef, TaskView } from "../bridge/contracts.ts";

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
      return { showsSelector: true, selectable: false, pending: true };
    case "catalog_unavailable":
      return { showsSelector: true, selectable: false, pending: false };
    case "task_unavailable":
    default:
      return { showsSelector: false, selectable: false, pending: false };
  }
}

/** Missing historical sources require an explicit choice, never inference. */
export function taskModelCandidates(
  models: ModelsView,
  intent: ModelRef | null,
) {
  const sources = [...models.providers, ...models.customProviders];
  if (intent && sources.some((provider) => provider.id === intent.sourceId))
    return readyModelOptions(models, intent.sourceId);
  return sources.flatMap((provider) => readyModelOptions(models, provider.id));
}
