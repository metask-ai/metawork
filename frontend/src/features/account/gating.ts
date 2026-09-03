import type { AccountView, ModelsView } from "../../bridge/contracts.ts";

function metaskIsDefault(
  models: Pick<ModelsView, "defaultSelection">,
): boolean {
  return (
    models.defaultSelection === null ||
    models.defaultSelection.sourceId.startsWith("metask:")
  );
}

export function requiresAccountGate(
  account: Pick<AccountView, "state">,
  models: Pick<ModelsView, "defaultSelection">,
): boolean {
  return (
    metaskIsDefault(models) &&
    (account.state === "checking" ||
      account.state === "signed_out" ||
      account.state === "authorizing")
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
  models: Pick<ModelsView, "providers" | "defaultSelection">,
): boolean {
  const metask = models.providers.find((provider) => provider.id === "metask");
  return (
    account.state === "authenticated" &&
    metaskIsDefault(models) &&
    (metask?.catalogState === "choosing" || metask?.catalogState === "failed")
  );
}
