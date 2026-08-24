import { useEffect, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";

export function AccountIdentity({
  account,
  active,
  disabled,
  onOpenSettings,
  onBeginLogin,
  onLogout,
}: {
  account: AccountView;
  active: boolean;
  disabled: boolean;
  onOpenSettings: () => void;
  onBeginLogin: () => void;
  onLogout: () => void;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const authenticated = account.state === "authenticated";
  const identityName = authenticated
    ? account.displayName || t("account.signed_in")
    : t("account.provider");
  const identityStatus = authenticated
    ? t("account.connected")
    : t("account.signed_out");
  const menuTitle = authenticated ? identityName : t("account.label");
  const initial = [...identityName.trim()][0]?.toLocaleUpperCase() || "M";

  useEffect(() => {
    if (!authenticated) setConfirmSignOut(false);
  }, [authenticated]);

  function choose(action: () => void) {
    setOpen(false);
    action();
  }

  return (
    <>
      <Menu.Root open={open} onOpenChange={setOpen}>
        <div className="account-identity">
          <Menu.Portal>
            <Menu.Positioner side="top" align="end" sideOffset={8}>
              <Menu.Popup
                className="account-menu"
                aria-label={t("account.menu")}
              >
                <div className="account-menu-heading">
                  <strong title={menuTitle}>{menuTitle}</strong>
                  <span>{identityStatus}</span>
                </div>
                {!authenticated && (
                  <Menu.Item
                    className="account-menu-item focus-ring"
                    disabled={disabled}
                    onClick={() => choose(onBeginLogin)}
                  >
                    <Icon name="account" />
                    {t("account.login")}
                  </Menu.Item>
                )}
                <Menu.Item
                  className="account-menu-item focus-ring"
                  onClick={() => choose(onOpenSettings)}
                >
                  <Icon name="settings" />
                  {t("settings.title")}
                </Menu.Item>
                {authenticated && (
                  <Menu.Item
                    className="account-menu-item is-danger focus-ring"
                    disabled={disabled}
                    onClick={() => choose(() => setConfirmSignOut(true))}
                  >
                    {t("account.logout_short")}
                  </Menu.Item>
                )}
              </Menu.Popup>
            </Menu.Positioner>
          </Menu.Portal>
          <Menu.Trigger
            className="account-identity-trigger focus-ring"
            data-active={active}
            aria-label={t("account.menu")}
          >
            <span className="account-avatar" aria-hidden="true">
              {initial}
            </span>
            <span className="account-identity-copy">
              <strong title={identityName}>{identityName}</strong>
              <small>{identityStatus}</small>
            </span>
            <Icon name="chevron" />
          </Menu.Trigger>
        </div>
      </Menu.Root>

      <AlertDialog.Root
        open={authenticated && confirmSignOut}
        onOpenChange={setConfirmSignOut}
      >
        <AlertDialog.Portal>
          <AlertDialog.Backdrop />
          <AlertDialog.Popup>
            <AlertDialog.Title>{t("settings.signout_title")}</AlertDialog.Title>
            <AlertDialog.Description>
              {t("account.logout_confirm")}
            </AlertDialog.Description>
            <div className="flex justify-end gap-2">
              <Button
                autoFocus
                type="button"
                variant="secondary"
                size="md"
                onClick={() => setConfirmSignOut(false)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                type="button"
                variant="danger"
                size="md"
                disabled={disabled}
                onClick={() => {
                  setConfirmSignOut(false);
                  onLogout();
                }}
              >
                {t("account.logout")}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </>
  );
}
