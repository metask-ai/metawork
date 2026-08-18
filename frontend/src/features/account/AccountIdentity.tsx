import { useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";

type SettingsTarget = "account" | "model_connections" | "signout";

export function AccountIdentity({
  account,
  active,
  disabled,
  onOpenSettings,
  onBeginLogin,
}: {
  account: AccountView;
  active: boolean;
  disabled: boolean;
  onOpenSettings: (target: SettingsTarget) => void;
  onBeginLogin: () => void;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const authenticated = account.state === "authenticated";
  const displayName = authenticated
    ? account.displayName || t("account.signed_in")
    : t("account.login");
  const initial = [...displayName.trim()][0]?.toLocaleUpperCase() || "M";

  function choose(action: () => void) {
    setOpen(false);
    action();
  }

  return (
    <Menu.Root open={open} onOpenChange={setOpen}>
      <div className="account-identity">
        <Menu.Portal>
          <Menu.Positioner side="top" align="end" sideOffset={8}>
            <Menu.Popup className="account-menu" aria-label={t("account.menu")}>
              <div className="account-menu-heading">
                <strong title={displayName}>{displayName}</strong>
                <span>
                  {authenticated
                    ? t("account.connected")
                    : t("account.sign_in_required.title")}
                </span>
              </div>
              {!authenticated && (
                <Menu.Item
                  className="account-menu-item is-attention focus-ring"
                  disabled={disabled}
                  onClick={() => choose(onBeginLogin)}
                >
                  {t("account.login")}
                </Menu.Item>
              )}
              <Menu.Item
                className="account-menu-item focus-ring"
                onClick={() => choose(() => onOpenSettings("account"))}
              >
                <Icon name="settings" />
                {t("settings.account")}
              </Menu.Item>
              <Menu.Item
                className="account-menu-item focus-ring"
                onClick={() =>
                  choose(() => onOpenSettings("model_connections"))
                }
              >
                <Icon name="model" />
                {t("settings.model_connections")}
              </Menu.Item>
              {authenticated && (
                <Menu.Item
                  className="account-menu-item is-danger focus-ring"
                  onClick={() => choose(() => onOpenSettings("signout"))}
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
            <strong title={displayName}>{displayName}</strong>
            <small>
              {authenticated ? t("account.connected") : t("account.login")}
            </small>
          </span>
          <Icon name="chevron" />
        </Menu.Trigger>
      </div>
    </Menu.Root>
  );
}
