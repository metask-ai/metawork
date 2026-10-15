import { useEffect, useState } from "react";
import type { QueuedInput, QueuedInputReason } from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";
import type { QueuedOperation } from "./queued-input.ts";

export function QueuedInputCard({
  queued,
  pending,
  busy,
  error,
  draftEmpty,
  preserveCurrent,
  disabled,
  onEdit,
  onWithdraw,
  onRefresh,
  onResolve,
  onConfirmationOpenChange,
}: {
  queued: QueuedInput | null;
  pending: QueuedOperation | null;
  busy: boolean;
  error: QueuedInputReason | "storage_unavailable" | null;
  draftEmpty: boolean;
  preserveCurrent: boolean;
  disabled: boolean;
  onEdit: () => void;
  onWithdraw: () => void;
  onRefresh: () => void;
  onResolve: (restore: boolean) => void;
  onConfirmationOpenChange?: (open: boolean) => void;
}) {
  const { t } = useI18n();
  const [confirming, setConfirming] = useState(false);
  function changeConfirmation(open: boolean) {
    setConfirming(open);
    onConfirmationOpenChange?.(open);
  }
  useEffect(
    () => () => onConfirmationOpenChange?.(false),
    [onConfirmationOpenChange],
  );
  useEffect(() => {
    if (!pending && confirming) changeConfirmation(false);
  }, [pending, confirming]);
  if (!queued && !pending && !error) return null;
  const conflict = pending?.phase === "draft_conflict";
  const restore = Boolean(pending?.draft && !preserveCurrent);
  const resolveLabel = preserveCurrent
    ? "queue.keep_current"
    : restore
      ? "queue.use_original"
      : "queue.continue";
  return (
    <section className="queued-input-card" aria-label={t("queue.card_label")}>
      {queued && (
        <>
          <p className="queued-input-state" role="status">
            {queued.state === "waiting"
              ? t("queue.waiting")
              : t("queue.held", {
                  reason: t(`queue.reason.${queued.heldReason!}`),
                })}
          </p>
          <p className="queued-input-preview" dir="auto">
            {queued.input.kind === "text"
              ? queued.input.text
              : `/${queued.input.invocationName} ${queued.input.argumentValues.join(" ")}`}
          </p>
          <small>{t("queue.memory_only")}</small>
          <div className="queued-input-actions">
            <Button
              type="button"
              variant="secondary"
              size="sm"
              disabled={disabled || Boolean(pending) || !draftEmpty}
              onClick={onEdit}
            >
              {t("queue.edit")}
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={disabled || Boolean(pending)}
              onClick={onWithdraw}
            >
              {t("queue.withdraw")}
            </Button>
          </div>
        </>
      )}
      {error && (
        <p role="alert" className="queued-input-error">
          {t("queue.rejected", {
            reason:
              error === "storage_unavailable"
                ? t("queue.storage_unavailable")
                : t(`queue.reason.${error}`),
          })}
        </p>
      )}
      {pending && (
        <div className="queued-input-reconciliation">
          <p role="status">
            {t(
              busy
                ? pending.kind === "queue"
                  ? "queue.pending"
                  : "queue.withdrawing"
                : conflict
                  ? "queue.draft_conflict"
                  : "queue.unconfirmed",
            )}
          </p>
          <div className="queued-input-actions">
            {!conflict && (
              <Button
                type="button"
                variant="secondary"
                size="sm"
                disabled={disabled}
                onClick={onRefresh}
              >
                {t("queue.refresh")}
              </Button>
            )}
            {conflict ? (
              <>
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  disabled={!draftEmpty}
                  onClick={() => onResolve(true)}
                >
                  {t("queue.restore")}
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => onResolve(false)}
                >
                  {t("queue.discard_returned")}
                </Button>
              </>
            ) : (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={busy}
                onClick={() => changeConfirmation(true)}
              >
                {t(resolveLabel)}
              </Button>
            )}
          </div>
        </div>
      )}
      <AlertDialog.Root open={confirming} onOpenChange={changeConfirmation}>
        <AlertDialog.Portal>
          <AlertDialog.Backdrop />
          <AlertDialog.Popup>
            <AlertDialog.Title>{t("queue.unconfirmed")}</AlertDialog.Title>
            <AlertDialog.Description>
              {t("queue.uncertain_confirm_body")}
            </AlertDialog.Description>
            <div className="delete-confirmation-actions">
              <Button
                autoFocus
                type="button"
                variant="secondary"
                size="md"
                onClick={() => changeConfirmation(false)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                type="button"
                variant="primary"
                size="md"
                onClick={() => {
                  changeConfirmation(false);
                  onResolve(restore);
                }}
              >
                {t(resolveLabel)}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </section>
  );
}
