import type { RefObject } from "react";
import type { UpdateView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { DiagnosticDisclosure } from "../../components/ui/DiagnosticDisclosure.tsx";
import { useI18n } from "../../i18n/context.ts";
import type { useUpdateActions } from "./update-actions.ts";
import { updateDiagnosticText } from "./update-diagnostics.ts";

export function CheckForUpdatesDialog({
  updates,
  actions,
  returnFocus,
}: {
  updates: UpdateView;
  actions: ReturnType<typeof useUpdateActions>;
  returnFocus: RefObject<HTMLButtonElement | null>;
}) {
  const { t } = useI18n();
  const { lastAction, checking, commandError, busy, act } = actions;
  const checkFailed =
    updates.checkState === "failed" ||
    updates.checkState === "unavailable" ||
    (lastAction === "check" && Boolean(commandError));
  const version =
    !checking &&
    !checkFailed &&
    updates.checkState === "succeeded" &&
    updates.updateAvailable
      ? updates.latestVersion
      : null;
  const website =
    !updates.downloadAvailable ||
    (lastAction !== "check" && updates.downloadState === "failed");

  function message() {
    if (checking) return t("updates.checking");
    const error =
      lastAction === "download" ? actions.errorMessage : commandError;
    if (error) return error;
    if (checkFailed) return t("updates.check_failed");
    if (lastAction === "download") {
      if (
        actions.pending === "download" ||
        updates.downloadState === "checking"
      )
        return t("updates.preparing");
      if (updates.downloadState === "opened")
        return t("updates.browser_opened");
    }
    if (version) return t("updates.new_version", { version });
    return t(
      updates.checkState === "succeeded"
        ? "updates.latest"
        : "updates.checking",
    );
  }

  return (
    <Dialog.Root
      open={lastAction !== null}
      onOpenChange={(open) => {
        if (!open) actions.reset();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup
          finalFocus={returnFocus}
          className="w-[min(20rem,calc(100vw-2rem))] gap-3 p-5"
        >
          <Dialog.Title>{t("updates.check")}</Dialog.Title>
          <Dialog.Description role="status">
            {message()}
            {version && !updates.downloadAvailable && (
              <span className="mt-1 block">{t("updates.package_missing")}</span>
            )}
          </Dialog.Description>
          {!checking &&
            updates.checkState === "failed" &&
            updates.checkDiagnostic && (
              <DiagnosticDisclosure label={t("updates.diagnostics")}>
                <pre className="feedback-notice-details">
                  {updateDiagnosticText(updates.checkDiagnostic, t)}
                </pre>
              </DiagnosticDisclosure>
            )}
          <div className="mt-2 flex flex-wrap justify-end gap-2">
            <Dialog.Close
              render={
                <Button
                  variant={version || checkFailed ? "secondary" : "primary"}
                />
              }
            >
              {t("common.ok")}
            </Dialog.Close>
            {checkFailed && !checking && (
              <Button
                disabled={actions.checkDisabled}
                onClick={() => void act("check")}
              >
                {t("updates.retry")}
              </Button>
            )}
            {version && (
              <Button
                disabled={busy}
                onClick={() => void act(website ? "website" : "download")}
              >
                {t(website ? "updates.website" : "updates.download")}
              </Button>
            )}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
