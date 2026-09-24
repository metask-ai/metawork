import { useEffect, useRef, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  accountIdentityInitial,
  accountIdentityLabel,
} from "../../workbench/account-identity.ts";
import { AboutMetaWorkDialog } from "./AboutMetaWorkDialog.tsx";

export function AccountIdentity({
  account,
  active,
  disabled,
  cancelDisabled,
  onOpenSettings,
  onBeginLogin,
  onCancel,
  onLogout,
}: {
  account: AccountView;
  active: boolean;
  disabled: boolean;
  cancelDisabled: boolean;
  onOpenSettings: () => void;
  onBeginLogin: () => void;
  onCancel: () => void;
  onLogout: () => void;
}) {
  const { t } = useI18n();
  const trigger = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const [aboutOpen, setAboutOpen] = useState(false);
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const authenticated = account.state === "authenticated";
  const identityName = authenticated
    ? accountIdentityLabel(account, t("account.signed_in"))
    : t("account.provider");
  const identityStatus =
    account.state === "checking"
      ? t("account.checking.title")
      : account.state === "authorizing"
        ? t("account.authorizing.title")
        : account.state === "signed_out"
          ? t("account.signed_out")
          : null;
  const initial = accountIdentityInitial(account);

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
                aria-label={t("app.account_and_application_menu")}
              >
                {authenticated && (
                  <div className="account-menu-heading">
                    <strong title={identityName}>{identityName}</strong>
                  </div>
                )}
                {account.state === "signed_out" && (
                  <Menu.Item
                    className="account-menu-item focus-ring"
                    disabled={disabled}
                    onClick={() => choose(onBeginLogin)}
                  >
                    <Icon name="account" />
                    {t("account.login")}
                  </Menu.Item>
                )}
                {account.state === "authorizing" && account.canCancel && (
                  <Menu.Item
                    className="account-menu-item focus-ring"
                    disabled={cancelDisabled}
                    onClick={() => choose(onCancel)}
                  >
                    <Icon name="close" />
                    {t("account.cancel")}
                  </Menu.Item>
                )}
                {(account.state === "signed_out" ||
                  (account.state === "authorizing" && account.canCancel)) && (
                  <Menu.Separator />
                )}
                <Menu.Item
                  className="account-menu-item focus-ring"
                  onClick={() => choose(onOpenSettings)}
                >
                  <Icon name="settings" />
                  {t("settings.title")}
                </Menu.Item>
                <Menu.Item
                  className="account-menu-item focus-ring"
                  onClick={() => choose(() => setAboutOpen(true))}
                >
                  <Icon name="info" />
                  {t("about.menu_item")}
                </Menu.Item>
                {authenticated && (
                  <>
                    <Menu.Separator />
                    <Menu.Item
                      className="account-menu-item focus-ring"
                      disabled={disabled}
                      onClick={() => choose(() => setConfirmSignOut(true))}
                    >
                      <Icon name="logout" />
                      {t("account.logout_short")}
                    </Menu.Item>
                  </>
                )}
              </Menu.Popup>
            </Menu.Positioner>
          </Menu.Portal>
          <Menu.Trigger
            ref={trigger}
            className="account-identity-trigger focus-ring"
            data-active={active}
            aria-label={t("app.account_and_application_menu")}
          >
            <span className="account-avatar" aria-hidden="true">
              {initial}
            </span>
            <span className="account-identity-copy">
              <strong title={identityName}>{identityName}</strong>
              {identityStatus && <small>{identityStatus}</small>}
            </span>
            <Icon name="chevron" />
          </Menu.Trigger>
        </div>
      </Menu.Root>

      <AboutMetaWorkDialog
        open={aboutOpen}
        onOpenChange={(nextOpen) => {
          setAboutOpen(nextOpen);
          if (!nextOpen)
            window.requestAnimationFrame(() => trigger.current?.focus());
        }}
      />

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
