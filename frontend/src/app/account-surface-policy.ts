import type { AccountView, ExecutionView } from "../bridge/contracts.ts";
import {
  requiresAccountGate,
  requiresAccountSetup,
} from "../features/account/gating.ts";

export type AccountSurfacePolicy = {
  gateRequired: boolean;
  setupRequired: boolean;
};

/**
 * Account onboarding may replace an empty Workbench, but it never becomes a
 * global gate once Product owns durable Tasks. New Task admission remains an
 * independent Execution fact.
 */
export function accountSurfacePolicy(
  account: Pick<AccountView, "state" | "catalogState">,
  execution: Pick<ExecutionView, "defaultSource">,
  hasTasks: boolean,
): AccountSurfacePolicy {
  if (hasTasks) return { gateRequired: false, setupRequired: false };
  return {
    gateRequired: requiresAccountGate(account, execution),
    setupRequired: requiresAccountSetup(account, execution),
  };
}
