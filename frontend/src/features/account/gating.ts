import type {
  AccountView,
  ExecutionView,
  ModelsView,
} from "../../bridge/contracts.ts";

export function requiresAccountGate(
  account: Pick<AccountView, "state">,
  execution: Pick<ExecutionView, "defaultSource">,
): boolean {
  return (
    execution.defaultSource !== "model_connection" &&
    (account.state === "checking" || account.state === "authorizing")
  );
}

/**
 * A Metask provider that needs a user decision must use the Host-owned Models
 * settings surface: `choosing` requires an API/model pick and `failed` owns the
 * retry action. `loading` is deliberately excluded — post-login
 * continuation resolves it automatically, and redirecting on a transient
 * state flashes the settings page on every startup while the catalog loads.
 */
export function requiresAccountSetup(
  account: Pick<AccountView, "state">,
  models: Pick<ModelsView, "providers">,
  execution: Pick<ExecutionView, "defaultSource">,
): boolean {
  const metask = models.providers.find((provider) => provider.id === "metask");
  return (
    account.state === "authenticated" &&
    execution.defaultSource !== "model_connection" &&
    (metask?.catalogState === "choosing" || metask?.catalogState === "failed")
  );
}
