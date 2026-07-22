import { useEffect, useRef, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

type SettingsTarget = "title" | "signout";

export function AccountIdentity({
  account,
  active,
  disabled,
  onOpenSettings,
  onReauthenticate,
}: {
  account: AccountView;
  active: boolean;
  disabled: boolean;
  onOpenSettings: (target: SettingsTarget) => void;
  onReauthenticate: () => void;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const displayName = account.displayName || t("account.signed_in");
  const initial = [...displayName.trim()][0]?.toLocaleUpperCase() || "M";
  const needsAttention = account.sessionState === "reauth_required";

  useEffect(() => {
    if (!open) return;
    const dismiss = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", dismiss);
    window.requestAnimationFrame(() =>
      root.current
        ?.querySelector<HTMLButtonElement>('[role="menuitem"]')
        ?.focus(),
    );
    return () => document.removeEventListener("mousedown", dismiss);
  }, [open]);

  function close(restoreFocus: boolean) {
    setOpen(false);
    if (restoreFocus)
      window.requestAnimationFrame(() => trigger.current?.focus());
  }

  function moveMenuFocus(event: React.KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      close(true);
      return;
    }
    if (event.key === "Tab") {
      setOpen(false);
      return;
    }
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    const items = [
      ...(root.current?.querySelectorAll<HTMLButtonElement>(
        '[role="menuitem"]:not(:disabled)',
      ) ?? []),
    ];
    if (items.length === 0) return;
    event.preventDefault();
    const current = items.indexOf(document.activeElement as HTMLButtonElement);
    const target =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? items.length - 1
          : event.key === "ArrowDown"
            ? (current + 1 + items.length) % items.length
            : (current - 1 + items.length) % items.length;
    items[target]?.focus();
  }

  return (
    <div className="account-identity" ref={root}>
      {open && (
        <div
          className="account-menu"
          role="menu"
          aria-label={t("account.menu")}
          onKeyDown={moveMenuFocus}
        >
          <div className="account-menu-heading">
            <strong title={displayName}>{displayName}</strong>
            <span>
              {needsAttention
                ? t("account.connection_attention")
                : t("account.connected")}
            </span>
          </div>
          {needsAttention && (
            <button
              role="menuitem"
              className="account-menu-item is-attention focus-ring"
              disabled={disabled}
              onClick={() => {
                close(false);
                onReauthenticate();
              }}
            >
              {t("account.reauthenticate")}
            </button>
          )}
          <button
            role="menuitem"
            className="account-menu-item focus-ring"
            onClick={() => {
              close(false);
              onOpenSettings("title");
            }}
          >
            <Icon name="settings" />
            {t("settings.account_models")}
          </button>
          <button
            role="menuitem"
            className="account-menu-item is-danger focus-ring"
            onClick={() => {
              close(false);
              onOpenSettings("signout");
            }}
          >
            {t("account.logout_short")}
          </button>
        </div>
      )}
      <button
        ref={trigger}
        className="account-identity-trigger focus-ring"
        data-active={active}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="account-avatar" aria-hidden="true">
          {initial}
        </span>
        <span className="account-identity-copy">
          <strong title={displayName}>{displayName}</strong>
          <small data-attention={needsAttention}>
            {needsAttention
              ? t("account.connection_attention")
              : t("account.connected")}
          </small>
        </span>
        <Icon name="chevron" />
      </button>
    </div>
  );
}
