import type {
  ModelsView,
  NewTaskAdmissionView,
  TaskView,
} from "../bridge/contracts.ts";

export type TaskModelSelectionPolicy = {
  authorityExact: boolean;
  catalogUsable: boolean;
};

/**
 * Renderer-side presentation of the Host's Task model authority rule.
 * This only suppresses actions that the Host must reject; it is never an
 * authorization boundary.
 */
export function taskModelSelectionPolicy(
  models: ModelsView,
  admission: NewTaskAdmissionView,
  task: TaskView | null,
): TaskModelSelectionPolicy {
  if (task === null)
    return {
      authorityExact: false,
      catalogUsable: false,
    };

  const metask = models.providers.find((provider) => provider.id === "metask");
  const selectedApi = metask?.apiKeys.find(
    (candidate) => candidate.id === metask.selectedApiKeyId,
  );
  const authorityExact =
    admission.available &&
    admission.activeModelRef?.sourceId === models.metaskSelection?.sourceId &&
    admission.activeGeneration !== "0" &&
    admission.activeSelectionRevision === models.selectionRevision &&
    task.binding.executionGeneration === admission.activeGeneration &&
    selectedApi?.protocol === task.binding.protocol;

  return {
    authorityExact,
    catalogUsable:
      authorityExact &&
      metask?.catalogState === "ready" &&
      metask.catalogGeneration !== "0" &&
      metask.models.length !== 0,
  };
}
