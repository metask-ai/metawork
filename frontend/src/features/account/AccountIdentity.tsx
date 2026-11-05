import { useEffect, useRef, useState } from "react";

import type { AccountView, UpdateView } from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  accountIdentityInitial,
  accountIdentityLabel,
} from "../../workbench/account-identity.ts";
import {
  AboutMetaWorkDialog,
  type UpdateControls,
} from "./AboutMetaWorkDialog.tsx";

export function AccountIdentity({
  account,
  active,
  disabled,
  cancelDisabled,
  onOpenSettings,
  onBeginLogin,
  onCancel,
  onLogout,
  updates,
  updateControls,
}: {
  account: AccountView;
  active: boolean;
  disabled: boolean;
  cancelDisabled: boolean;
  onOpenSettings: () => void;
  onBeginLogin: () => void;
  onCancel: () => void;
  onLogout: () => void;
  updates: UpdateView;
  updateControls: UpdateControls;
}) {
  const { t } = useI18n();
  const trigger = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const [aboutOpen, setAboutOpen] = useState(false);
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const aboutReturnFocus = useRef<HTMLButtonElement | null>(null);
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
                  <>
                    <div className="account-menu-heading">
                      <strong title={identityName}>{identityName}</strong>
                    </div>
                    <Menu.Separator />
                  </>
                )}
                {(account.state === "signed_out" ||
                  (authenticated &&
                    account.errorCode !== "none" &&
                    account.errorCode !== "refresh_schedule_failed")) && (
                  <Menu.Item
                    disabled={disabled}
                    onClick={() => choose(onBeginLogin)}
                  >
                    <Icon name="account" />
                    {t("account.login")}
                  </Menu.Item>
                )}
                {account.state === "authorizing" && account.canCancel && (
                  <Menu.Item
                    disabled={cancelDisabled}
                    onClick={() => choose(onCancel)}
                  >
                    <Icon name="close" />
                    {t("account.cancel")}
                  </Menu.Item>
                )}
                {(account.state === "signed_out" ||
                  (authenticated &&
                    account.errorCode !== "none" &&
                    account.errorCode !== "refresh_schedule_failed") ||
                  (account.state === "authorizing" && account.canCancel)) && (
                  <Menu.Separator />
                )}
                <Menu.Item onClick={() => choose(onOpenSettings)}>
                  <Icon name="settings" />
                  {t("settings.title")}
                </Menu.Item>
                <Menu.Item
                  onClick={() =>
                    choose(() => {
                      aboutReturnFocus.current = trigger.current;
                      setAboutOpen(true);
                    })
                  }
                >
                  <Icon name="info" />
                  {t("about.menu_item")}
                </Menu.Item>
                {authenticated && (
                  <>
                    <Menu.Separator />
                    <Menu.Item
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
          </Menu.Trigger>
          {updates.updateAvailable && (
            <button
              type="button"
              className="account-update-trigger focus-ring"
              aria-label={t("updates.open", {
                version: updates.latestVersion!,
              })}
              disabled={updateControls.disabled}
              onClick={(event) => {
                aboutReturnFocus.current = event.currentTarget;
                choose(() => setAboutOpen(true));
              }}
            >
              {t("updates.available")}
            </button>
          )}
        </div>
      </Menu.Root>

      <AboutMetaWorkDialog
        updates={updates}
        updateControls={updateControls}
        open={aboutOpen}
        onOpenChange={(nextOpen) => {
          setAboutOpen(nextOpen);
          if (!nextOpen)
            window.requestAnimationFrame(() => {
              const target = aboutReturnFocus.current;
              (target?.isConnected ? target : trigger.current)?.focus();
            });
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
