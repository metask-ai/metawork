import { useRef } from "react";

import { useI18n } from "../i18n/context.ts";
import { AlertDialog } from "./ui/alert-dialog.tsx";
import { Button } from "./ui/button.tsx";

export function SignOutConfirmation({
  disabled,
  onLogout,
}: {
  disabled: boolean;
  onLogout: () => void;
}) {
  const { t } = useI18n();
  const cancel = useRef<HTMLButtonElement>(null);

  return (
    <AlertDialog.Portal>
      <AlertDialog.Backdrop />
      <AlertDialog.Popup initialFocus={cancel}>
        <AlertDialog.Title>{t("account.logout")}</AlertDialog.Title>
        <AlertDialog.Description>
          {t("account.logout_confirm")}
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
