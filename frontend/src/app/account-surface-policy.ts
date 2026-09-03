import type { AccountView, ModelsView } from "../bridge/contracts.ts";
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
 * independent Product Control fact.
 */
export function accountSurfacePolicy(
  account: Pick<AccountView, "state">,
  models: Pick<ModelsView, "providers" | "defaultSelection">,
  hasTasks: boolean,
): AccountSurfacePolicy {
  if (hasTasks) return { gateRequired: false, setupRequired: false };
  return {
    gateRequired: requiresAccountGate(account, models),
    setupRequired: requiresAccountSetup(account, models),
  };
}
