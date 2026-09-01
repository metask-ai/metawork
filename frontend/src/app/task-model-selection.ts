import type { AccountView, TaskView } from "../bridge/contracts.ts";

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
  account: AccountView,
  task: TaskView | null,
): TaskModelSelectionPolicy {
  if (task === null)
    return {
      authorityExact: false,
      catalogUsable: false,
    };

  const selectedApi = account.apiKeys.find(
    (candidate) => candidate.selectionId === account.selectedApiKeySelectionId,
  );
  const authorityExact =
    account.state === "authenticated" &&
    account.canCreateTask &&
    account.executionSource === "metask" &&
    account.executionGeneration !== "0" &&
    account.executionGeneration === account.metaskExecutionGeneration &&
    task.binding.executionGeneration === account.executionGeneration &&
    selectedApi?.protocol === task.binding.protocol;

  return {
    authorityExact,
    catalogUsable:
      authorityExact &&
      account.catalogState === "ready" &&
      account.catalogGeneration !== "0" &&
      account.models.length !== 0,
  };
}
