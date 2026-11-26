import logoMarkUrl from "../../../../assets/brand/logo-mark.svg?url";
import { productVersion } from "../../app/product-identity.ts";
import type { UpdateView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { DiagnosticDisclosure } from "../../components/ui/DiagnosticDisclosure.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { type UpdateControls, useUpdateActions } from "./update-actions.ts";
import { updateDiagnosticText } from "./update-diagnostics.ts";

export function AboutMetaWorkDialog({
  open,
  onOpenChange,
  updates,
  updateControls,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  updates: UpdateView;
  updateControls: UpdateControls;
}) {
  const { t } = useI18n();
  const { act, errorMessage, busy, checking, checkDisabled } = useUpdateActions(
    updates,
    updateControls,
    open,
  );
  const preparing = updates.downloadState === "checking";
  const status = updates.updateAvailable
    ? t("updates.new_version", { version: updates.latestVersion! })
    : checking
      ? t("updates.checking")
      : updates.checkState === "succeeded"
        ? t("updates.latest")
        : updates.checkState === "unchecked"
          ? t("updates.check_hint")
          : t("updates.check_failed");

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup className="about-dialog">
          <Dialog.Close
            className="about-dialog-close"
            aria-label={t("common.close")}
          >
            <Icon name="close" />
          </Dialog.Close>

          <div className="about-dialog-product">
            <span className="about-dialog-mark" aria-hidden="true">
              <img src={logoMarkUrl} alt="" />
            </span>
            <div>
              <Dialog.Title>{t("app.name")}</Dialog.Title>
            </div>
          </div>

          <dl className="about-dialog-build">
            <div>
              <dt>{t("about.developer")}</dt>
              <dd>{t("about.developer_name")}</dd>
            </div>
            <div>
              <dt>{t("about.version")}</dt>
              <dd>
                <code>{productVersion}</code>
              </dd>
            </div>
          </dl>

          <section className="about-updates" aria-label={t("updates.section")}>
            <div
              className="about-update-status"
              role="status"
              aria-live="polite"
            >
              <p>{status}</p>
              {updates.updateAvailable && checking && (
                <small>{t("updates.checking")}</small>
              )}
              {updates.updateAvailable && updates.checkState === "failed" && (
                <small>{t("updates.last_known")}</small>
              )}
              {updates.updateAvailable && !updates.downloadAvailable && (
                <small>{t("updates.package_missing")}</small>
              )}
              {preparing && <small>{t("updates.preparing")}</small>}
              {updates.downloadState === "opened" && (
                <small>{t("updates.browser_opened")}</small>
              )}
            </div>
            {errorMessage && (
              <p className="about-update-error" role="alert">
                {errorMessage}
              </p>
            )}
            {updates.checkDiagnostic && (
              <DiagnosticDisclosure label={t("updates.diagnostics")}>
                <pre className="feedback-notice-details">
                  {updateDiagnosticText(updates.checkDiagnostic, t)}
                </pre>
              </DiagnosticDisclosure>
            )}
            <div className="about-update-actions">
              {updates.downloadAvailable && (
                <Button
                  type="button"
                  size="md"
                  disabled={busy || checking}
                  onClick={() => void act("download")}
                >
                  {t("updates.download")}
                </Button>
              )}
              <Button
                type="button"
                variant="secondary"
                size="md"
                disabled={checkDisabled}
                onClick={() => void act("check")}
              >
                {updates.checkState === "failed"
                  ? t("updates.retry")
                  : t("updates.check")}
              </Button>
              <Button
                type="button"
                variant="secondary"
                size="md"
                disabled={busy}
                onClick={() => void act("website")}
              >
                {t("updates.website")}
              </Button>
            </div>
          </section>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
