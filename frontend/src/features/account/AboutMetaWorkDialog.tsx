import logoMarkUrl from "../../../../assets/brand/logo-mark.svg?url";
import { useEffect, useRef, useState } from "react";
import { productVersion } from "../../app/product-identity.ts";
import type { UpdateView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export type UpdateControls = {
  disabled: boolean;
  generation: string;
  check: () => Promise<boolean>;
  download: (expectedVersion: string) => Promise<boolean>;
  website: () => Promise<boolean>;
};

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
  const [pending, setPending] = useState<
    "check" | "download" | "website" | null
  >(null);
  const [actionError, setActionError] = useState<
    "unavailable" | "browser" | "unknown" | null
  >(null);
  const request = useRef(0);
  const inFlight = useRef(false);
  useEffect(() => {
    request.current += 1;
    inFlight.current = false;
    setPending(null);
    setActionError(null);
    return () => {
      request.current += 1;
      inFlight.current = false;
    };
  }, [open, updateControls.disabled, updateControls.generation]);

  async function act(action: "check" | "download" | "website") {
    if (inFlight.current || updateControls.disabled) return;
    const version = updates.latestVersion;
    if (action === "download" && version === null) return;
    const current = ++request.current;
    inFlight.current = true;
    setPending(action);
    setActionError(null);
    try {
      const accepted =
        action === "check"
          ? await updateControls.check()
          : action === "download"
            ? await updateControls.download(version!)
            : await updateControls.website();
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
  const busy = pending !== null || preparing;
  const checking = updates.checkState === "checking" || pending === "check";
  const downloadError = updates.downloadError;
  const errorMessage =
    actionError === "unknown"
      ? t("updates.command_unknown")
      : actionError === "browser"
        ? t("updates.browser_failed")
        : updates.downloadState === "failed"
          ? downloadError === "invalid_link" ||
            downloadError === "missing_download"
            ? t("updates.link_invalid")
            : downloadError === "stale_version"
              ? t("updates.version_changed")
              : downloadError === "browser_unavailable"
                ? t("updates.browser_failed")
                : t("updates.download_unavailable")
          : actionError === "unavailable"
            ? t("updates.action_unavailable")
            : null;
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
            <div className="about-update-actions">
              {updates.downloadAvailable && (
                <Button
                  type="button"
                  size="md"
                  disabled={updateControls.disabled || busy || checking}
                  onClick={() => void act("download")}
                >
                  {t("updates.download")}
                </Button>
              )}
              <Button
                type="button"
                variant="secondary"
                size="md"
                disabled={
                  updateControls.disabled ||
                  busy ||
                  checking ||
                  updates.checkState === "unavailable"
                }
                onClick={() => void act("check")}
              >
                {updates.checkState === "failed"
                  ? t("updates.retry")
                  : t("updates.check")}
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="md"
                disabled={updateControls.disabled || busy}
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
