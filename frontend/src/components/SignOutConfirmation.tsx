import { useRef } from "react";

import { useI18n } from "../i18n/context.ts";
import { signOutStopsMessageId } from "../i18n/formatters.ts";
import { AlertDialog } from "./ui/alert-dialog.tsx";
import { Button } from "./ui/button.tsx";

export function SignOutConfirmation({
  disabled,
  stopTargets,
  onLogout,
}: {
  disabled: boolean;
  /** Tasks whose Metask Run signing out stops. */
  stopTargets: number;
  onLogout: () => void;
}) {
  const { locale, t } = useI18n();
  const cancel = useRef<HTMLButtonElement>(null);

  return (
    <AlertDialog.Portal>
      <AlertDialog.Backdrop />
      <AlertDialog.Popup initialFocus={cancel}>
        <AlertDialog.Title>{t("account.logout")}</AlertDialog.Title>
        <AlertDialog.Description>
          {t("account.logout_confirm")}
          {stopTargets > 0 &&
            ` ${t(signOutStopsMessageId(locale, stopTargets), { count: String(stopTargets) })}`}
        </AlertDialog.Description>
        <div className="flex justify-end gap-2">
          <AlertDialog.Close
            ref={cancel}
            render={<Button variant="secondary" />}
          >
            {t("common.cancel")}
          </AlertDialog.Close>
          <AlertDialog.Close
            render={<Button variant="danger" />}
            disabled={disabled}
            onClick={onLogout}
          >
            {t("account.logout")}
          </AlertDialog.Close>
        </div>
      </AlertDialog.Popup>
    </AlertDialog.Portal>
  );
}
