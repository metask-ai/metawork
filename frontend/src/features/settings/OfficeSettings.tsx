import { useRef, useState } from "react";
import type {
  OfficeComponentView,
  OfficeComponentResult,
} from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

export type OfficeAction =
  "install" | "repair" | "remove" | "retry" | "cleanup";
const reasons: Record<
  NonNullable<OfficeComponentResult["reason"]>,
  MessageId
> = {
  unsupported_platform: "office.unsupported",
  unavailable: "office.unavailable",
  unpublished: "office.unpublished",
  stale_generation: "office.changed",
  busy: "office.busy",
  recovery_required: "office.check_required",
  not_installed: "office.changed",
  already_installed: "office.changed",
  not_needed: "office.changed",
  nothing_to_clean: "office.changed",
  too_late: "office.finishing",
  shutting_down: "office.restart",
  revision_exhausted: "office.restart",
  download_failed: "office.download_failed",
  invalid_component: "office.invalid_component",
  insufficient_space: "office.insufficient_space",
  resource_limit: "office.resource_limit",
  process_cleanup_incomplete: "office.restart",
  write_failed: "office.write_failed",
  outcome_unknown: "office.unknown",
  cleanup_failed: "office.cleanup_failed",
};

function bytes(value: string, locale: string) {
  const amount = Number(value);
  const unit = amount >= 1024 ** 3 ? "GiB" : "MiB";
  const divisor = unit === "GiB" ? 1024 ** 3 : 1024 ** 2;
  return `${new Intl.NumberFormat(locale === "pseudo" ? "en-US" : locale, { maximumFractionDigits: 1 }).format(amount / divisor)} ${unit}`;
}

export function OfficeSettings({
  view,
  disabled,
  onAction,
  onCancel,
}: {
  view: OfficeComponentView;
  disabled: boolean;
  onAction: (
    action: OfficeAction,
    generation: string,
  ) => Promise<OfficeComponentResult | null>;
  onCancel: (id: string) => Promise<OfficeComponentResult | null>;
}) {
  const { t, locale } = useI18n();
  const pending = useRef(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<MessageId | null>(null);
  const [removal, setRemoval] = useState<string | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const operation = view.operation;
  const knownProgress = operation !== null && BigInt(operation.total) > 0n;
  const percentage = knownProgress
    ? Math.min(100, (Number(operation.bytes) / Number(operation.total)) * 100)
    : undefined;
  const terminalError =
    view.terminal?.outcome === "failed" && view.terminal.reason
      ? reasons[view.terminal.reason]
      : null;
  const failure = error ?? terminalError;
  const blocked = disabled || busy;
  const status: MessageId = operation
    ? "office.working"
    : !view.supported
      ? "office.not_available"
      : view.health !== "ready"
        ? "office.needs_check"
        : view.current?.state === "ready"
          ? "office.ready"
          : view.current
            ? "office.needs_check"
            : "office.not_installed";
  const detail: MessageId | null = operation
    ? null
    : !view.supported
      ? "office.unsupported"
      : view.health === "restart_required"
        ? "office.restart"
        : view.health !== "ready"
          ? "office.check_required"
          : view.current?.state === "ready"
            ? "office.existing_tasks"
            : view.current?.state === "incompatible"
              ? "office.incompatible"
              : view.current
                ? "office.check_required"
                : !view.offered
                  ? "office.unpublished"
                  : null;

  async function submit(
    action: OfficeAction | "cancel",
    generation = view.generation,
  ) {
    if (disabled || pending.current) return;
    pending.current = true;
    setBusy(true);
    setError(null);
    try {
      const result =
        action === "cancel" && operation
          ? await onCancel(operation.id)
          : action !== "cancel"
            ? await onAction(action, generation)
            : null;
      if (result?.accepted) setRemoval(null);
      else {
        setError(result?.reason ? reasons[result.reason] : "office.unknown");
        if (action === "remove") setRemoval(null);
      }
    } catch {
      setError("office.unknown");
      if (action === "remove") setRemoval(null);
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }

  return (
    <div className="settings-group" data-office-component="">
      <h3
        className="settings-group-label focus-ring"
        ref={heading}
        tabIndex={-1}
      >
        {t("office.title")}
      </h3>
      <div className="settings-preference-list settings-office">
        <div className="settings-row">
          <div className="settings-office-copy">
            <span className="settings-row-label">
              {t("office.environment")}
            </span>
            <p>{t("office.help")}</p>
          </div>
          <span
            className="settings-office-status"
            data-ready={view.current?.state === "ready" && !operation}
          >
            {t(status)}
          </span>
        </div>
        <div className="settings-office-body">
          {detail && detail !== failure && <p>{t(detail)}</p>}
          {view.offered && (
            <p className="settings-office-size">
              {t("office.size", {
                download: bytes(view.offered.downloadBytes, locale),
                installed: bytes(view.offered.installedBytes, locale),
              })}
            </p>
          )}
          {operation && (
            <div className="settings-office-operation">
              <p role="status">
                {t(
                  operation.cancelling
                    ? "office.cancelling"
                    : `office.phase.${operation.phase}`,
                )}
              </p>
              {knownProgress && (
                <div
                  className="settings-office-progress"
                  role="progressbar"
                  aria-label={t("office.progress")}
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={percentage}
                >
                  <span
                    style={{
                      width: `${percentage}%`,
                    }}
                  />
                </div>
              )}
              {knownProgress && (
                <small>
                  {bytes(operation.bytes, locale)} /{" "}
                  {bytes(operation.total, locale)}
                </small>
              )}
            </div>
          )}
          {view.cleanupPending && <p>{t("office.cleanup_pending")}</p>}
          {view.terminal?.outcome === "cancelled" && !operation && (
            <p role="status">{t("office.cancelled")}</p>
          )}
          <div className="settings-office-actions">
            {view.actions.install && (
              <Button disabled={blocked} onClick={() => void submit("install")}>
                {t(view.updateAvailable ? "office.update" : "office.install")}
              </Button>
            )}
            {view.actions.repair && !view.actions.install && (
              <Button
                variant={
                  view.current?.state === "ready" ? "secondary" : "primary"
                }
                disabled={blocked}
                onClick={() => void submit("repair")}
              >
                {t("office.repair")}
              </Button>
            )}
            {view.actions.retry && (
              <Button
                variant="secondary"
                disabled={blocked}
                onClick={() => void submit("retry")}
              >
                {t("office.retry")}
              </Button>
            )}
            {view.actions.cleanup && (
              <Button
                variant="secondary"
                disabled={blocked}
                onClick={() => void submit("cleanup")}
              >
                {t("office.cleanup")}
              </Button>
            )}
            {view.current && (
              <Button
                variant="danger"
                disabled={blocked || !view.actions.remove}
                onClick={() => setRemoval(view.generation)}
              >
                {t("office.remove")}
              </Button>
            )}
            {operation && operation.kind !== "check" && (
              <Button
                variant="secondary"
                disabled={blocked || !view.actions.cancel}
                onClick={() => void submit("cancel")}
              >
                {t(
                  operation.cancelling ? "office.cancelling" : "common.cancel",
                )}
              </Button>
            )}
          </div>
          {view.cleanupPending && <small>{t("office.shared")}</small>}
          {failure && removal === null && (
            <p className="settings-office-error" role="alert">
              {t(failure)}
            </p>
          )}
        </div>
      </div>
      <AlertDialog.Root
        open={removal !== null}
        onOpenChange={(open) => {
          if (!open && !busy) setRemoval(null);
        }}
      >
        <AlertDialog.Portal>
          <AlertDialog.Backdrop />
          <AlertDialog.Popup
            className="office-removal-dialog"
            finalFocus={heading}
          >
            <AlertDialog.Title>{t("office.remove_title")}</AlertDialog.Title>
            <AlertDialog.Description>
              {t("office.remove_description")}
            </AlertDialog.Description>
            <p className="settings-office-shared">{t("office.shared")}</p>
            {failure && (
              <p className="settings-office-error" role="alert">
                {t(failure)}
              </p>
            )}
            <div className="delete-confirmation-actions">
              <Button
                autoFocus
                variant="secondary"
                disabled={busy}
                onClick={() => setRemoval(null)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                variant="danger"
                disabled={blocked || !view.actions.remove}
                onClick={() =>
                  void submit("remove", removal ?? view.generation)
                }
              >
                {t("office.remove")}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </div>
  );
}
