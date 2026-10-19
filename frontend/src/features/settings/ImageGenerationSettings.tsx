import { useEffect, useRef, useState } from "react";

import type {
  AccountView,
  MetaskImageGenerationView,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { useI18n } from "../../i18n/context.ts";

export function ImageGenerationSettings({
  account,
  image,
  disabled,
  onRefresh,
  onSelect,
}: {
  account: AccountView;
  image: MetaskImageGenerationView;
  disabled: boolean;
  onRefresh: () => void;
  onSelect: (modelId: string | null) => Promise<boolean>;
}) {
  const { t } = useI18n();
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  const inFlight = useRef(false);
  const authenticated = account.state === "authenticated";
  const ready = image.catalogState === "ready";
  const blocked = disabled || pending || !authenticated || !ready;
  const selected = image.models.find(
    (model) => model.id === image.selection?.modelId,
  );

  useEffect(
    () => setFailed(false),
    [account.accountId, image.selectionRevision, image.catalogGeneration],
  );

  async function select(modelId: string | null) {
    if (blocked || inFlight.current) return;
    inFlight.current = true;
    setPending(true);
    setFailed(false);
    try {
      setFailed(!(await onSelect(modelId)));
    } catch {
      setFailed(true);
    } finally {
      inFlight.current = false;
      setPending(false);
    }
  }

  const status = pending
    ? t("settings.image_saving")
    : !authenticated
      ? t("settings.image_needs_auth")
      : image.catalogState === "loading"
        ? t("settings.image_loading")
        : !ready
          ? t("settings.image_catalog_failed")
          : image.selection && !image.selectionAvailable
            ? t("settings.image_unavailable")
            : image.selectionAvailable
              ? t("settings.image_selected")
              : image.models.length === 0
                ? t("settings.image_no_models")
                : t("settings.image_unselected");

  return (
    <div
      className="settings-group settings-image-models"
      role="group"
      aria-labelledby="settings-image-title"
      aria-busy={pending || undefined}
    >
      <h3 id="settings-image-title" className="settings-group-label">
        {t("settings.image_title")}
      </h3>
      <div className="settings-preference-list">
        <div className="settings-image-content">
          <div className="settings-image-heading">
            <p>{t("settings.image_help")}</p>
            <Button
              variant="ghost"
              size="lg"
              disabled={
                disabled ||
                pending ||
                !authenticated ||
                image.catalogState === "loading"
              }
              onClick={onRefresh}
            >
              {t("account.refresh_catalog")}
            </Button>
          </div>
          <div className="settings-image-controls">
            <SelectionMenu
              triggerId="settings-image-model"
              value={
                image.selectionAvailable ? (image.selection?.modelId ?? "") : ""
              }
              options={image.models.map((model) => ({
                value: model.id,
                label: model.displayName || model.id,
                description: model.id,
              }))}
              placeholder={t("settings.image_choose")}
              ariaLabel={t("settings.image_title")}
              triggerClassName="settings-image-trigger"
              disabled={blocked || image.models.length === 0}
              busy={pending}
              onValueChange={(modelId) => void select(modelId)}
            />
            <Button
              variant="secondary"
              size="lg"
              disabled={blocked || image.selection === null}
              onClick={() => void select(null)}
            >
              {t("settings.image_clear")}
            </Button>
          </div>
          <p
            className="settings-image-status"
            role="status"
            aria-live="polite"
            data-unavailable={
              (ready &&
                image.selection !== null &&
                !image.selectionAvailable) ||
              undefined
            }
          >
            {status}
            {image.selection && !pending && (
              <>
                {" "}
                <strong>
                  {selected?.displayName || image.selection.modelId}
                </strong>
              </>
            )}
          </p>
          {failed && (
            <p className="settings-image-error" role="alert">
              {t("settings.image_save_failed")}
            </p>
          )}
          <p className="settings-image-note">{t("settings.image_billing")}</p>
        </div>
      </div>
    </div>
  );
}
