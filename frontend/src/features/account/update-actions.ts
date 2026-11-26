import { useCallback, useEffect, useRef, useState } from "react";
import type { UpdateView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

type UpdateAction = "check" | "download" | "website";

export type UpdateControls = {
  disabled: boolean;
  generation: string;
  check: () => Promise<boolean>;
  download: (expectedVersion: string) => Promise<boolean>;
  website: () => Promise<boolean>;
};

export function useUpdateActions(
  updates: UpdateView,
  updateControls: UpdateControls,
  open = true,
) {
  const { t } = useI18n();
  const [lastAction, setLastAction] = useState<UpdateAction | null>(null);
  const [pending, setPending] = useState<UpdateAction | null>(null);
  const [actionError, setActionError] = useState<
    "unavailable" | "browser" | "unknown" | null
  >(null);
  const request = useRef(0);
  const inFlight = useRef(false);
  const reset = useCallback(() => {
    request.current += 1;
    inFlight.current = false;
    setPending(null);
    setLastAction(null);
    setActionError(null);
  }, []);
  useEffect(() => {
    reset();
    return () => {
      request.current += 1;
      inFlight.current = false;
    };
  }, [open, updateControls.disabled, updateControls.generation, reset]);

  async function act(
    action: UpdateAction,
    openWebsite = updateControls.website,
  ) {
    if (inFlight.current || updateControls.disabled) return;
    const version = updates.latestVersion;
    if (action === "download" && version === null) return;
    const current = ++request.current;
    inFlight.current = true;
    setLastAction(action);
    setPending(action);
    setActionError(null);
    try {
      const accepted =
        action === "check"
          ? await updateControls.check()
          : action === "download"
            ? await updateControls.download(version!)
            : await openWebsite();
      if (request.current === current && !accepted)
        setActionError(action === "website" ? "browser" : "unavailable");
    } catch {
      if (request.current === current) setActionError("unknown");
    } finally {
      if (request.current === current) {
        inFlight.current = false;
        setPending(null);
      }
    }
  }

  const preparing = updates.downloadState === "checking";
  const busy = updateControls.disabled || pending !== null || preparing;
  const checking = updates.checkState === "checking" || pending === "check";
  const checkDisabled =
    busy || checking || updates.checkState === "unavailable";
  const downloadError = updates.downloadError;
  const commandError =
    actionError === "unknown"
      ? t("updates.command_unknown")
      : actionError === "browser"
        ? t("updates.browser_failed")
        : actionError === "unavailable"
          ? t("updates.action_unavailable")
          : null;
  let errorMessage = commandError;
  if (
    updates.downloadState === "failed" &&
    (!actionError || actionError === "unavailable")
  ) {
    switch (downloadError) {
      case "invalid_link":
      case "missing_download":
        errorMessage = t("updates.link_invalid");
        break;
      case "stale_version":
        errorMessage = t("updates.version_changed");
        break;
      case "browser_unavailable":
        errorMessage = t("updates.browser_failed");
        break;
      default:
        errorMessage = t("updates.download_unavailable");
    }
  }
  return {
    act,
    reset,
    lastAction,
    pending,
    commandError,
    errorMessage,
    busy,
    checking,
    checkDisabled,
  };
}
