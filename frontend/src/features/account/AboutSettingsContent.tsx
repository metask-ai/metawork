import { useRef, useState } from "react";
import { productVersion } from "../../app/product-identity.ts";
import type { UpdateView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { CheckForUpdatesDialog } from "./CheckForUpdatesDialog.tsx";
import { type UpdateControls, useUpdateActions } from "./update-actions.ts";

export function AboutSettingsContent({
  updates,
  updateControls,
  onOpenExternalLink,
}: {
  updates: UpdateView;
  updateControls: UpdateControls;
  onOpenExternalLink: (url: string) => Promise<boolean>;
}) {
  const { t } = useI18n();
  const checkButton = useRef<HTMLButtonElement>(null);
  const [showCheck, setShowCheck] = useState(false);
  const actions = useUpdateActions(updates, updateControls);
  const linksDisabled = updateControls.disabled || actions.pending !== null;

  function visit(open: () => Promise<boolean>) {
    setShowCheck(false);
    void actions.act("website", open);
  }

  return (
    <>
      <div className="settings-preference-list">
        <div className="settings-about-row">
          <div className="flex min-w-0 flex-wrap items-baseline gap-x-1.5">
            <span className="font-semibold">{t("about.current_version")}</span>
            <span className="text-xs text-(--ui-content-muted)">
              v{productVersion}
            </span>
          </div>
          <Button
            ref={checkButton}
            size="sm"
            variant="secondary"
            disabled={actions.checkDisabled}
            onClick={() => {
              setShowCheck(true);
              void actions.act("check");
            }}
          >
            {t("updates.check")}
          </Button>
        </div>
        <div className="settings-about-row settings-about-links">
          <span>{t("settings.about_product", { product: t("app.name") })}</span>
          <div className="ms-auto flex max-w-full flex-wrap justify-end gap-2">
            <Button
              size="sm"
              variant="secondary"
              disabled={linksDisabled}
              onClick={() => visit(updateControls.website)}
            >
              {t("about.visit_website")}
              <Icon name="external-link" />
            </Button>
            <Button
              size="sm"
              variant="secondary"
              disabled={linksDisabled}
              onClick={() =>
                visit(() =>
                  onOpenExternalLink(
                    "https://metawork.metask-ai.com/contact.html",
                  ),
                )
              }
            >
              {t("about.contact_us")}
              <Icon name="external-link" />
            </Button>
          </div>
        </div>
      </div>
      {!showCheck && actions.commandError && (
        <p role="alert" className="about-update-error">
          {actions.commandError}
        </p>
      )}
      {showCheck && (
        <CheckForUpdatesDialog
          updates={updates}
          actions={actions}
          returnFocus={checkButton}
        />
      )}
    </>
  );
}
