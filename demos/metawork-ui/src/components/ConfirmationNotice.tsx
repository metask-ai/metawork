import { useState } from "react";

import { Icon } from "./ui/Icon.tsx";
import { AlertDialog } from "./ui/alert-dialog.tsx";
import { Button } from "./ui/button.tsx";

export function ConfirmationNotice({
  message,
  detail,
  actionLabel,
  dialogTitle,
  dialogDescription,
  cancelLabel,
  confirmLabel,
  pendingLabel,
  failureMessage,
  actionAvailable,
  disabled,
  className,
  onConfirm,
}: {
  message: string;
  detail: string;
  actionLabel: string;
  dialogTitle: string;
  dialogDescription: string;
  cancelLabel: string;
  confirmLabel: string;
  pendingLabel: string;
  failureMessage: string;
  actionAvailable: boolean;
  disabled: boolean;
  className: string;
  onConfirm: () => Promise<string | null>;
}) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function confirm() {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const message = await onConfirm();
      if (message === null) setConfirming(false);
      else setError(message);
    } catch {
      setError(failureMessage);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className={className} role="alert">
        <Icon name="warning" />
        <div className="confirmation-notice-copy">
          <span>{message}</span>
          {actionAvailable && <small>{detail}</small>}
          {error && <small role="status">{error}</small>}
        </div>
        {actionAvailable && (
          <Button
            type="button"
            variant="secondary"
            size="sm"
            disabled={disabled || busy}
            onClick={() => setConfirming(true)}
          >
            {actionLabel}
          </Button>
        )}
      </div>

      <AlertDialog.Root open={confirming} onOpenChange={setConfirming}>
        <AlertDialog.Portal>
          <AlertDialog.Backdrop />
          <AlertDialog.Popup>
            <AlertDialog.Title>{dialogTitle}</AlertDialog.Title>
            <AlertDialog.Description>
              {dialogDescription}
            </AlertDialog.Description>
            <div className="delete-confirmation-actions">
              <Button
                autoFocus
                type="button"
                variant="secondary"
                disabled={busy}
                onClick={() => setConfirming(false)}
              >
                {cancelLabel}
              </Button>
              <Button
                type="button"
                variant="primary"
                disabled={busy}
                onClick={() => void confirm()}
              >
                {busy ? pendingLabel : confirmLabel}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </>
  );
}
