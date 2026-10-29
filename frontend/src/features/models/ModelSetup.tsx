import { useRef, type RefObject } from "react";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { accountErrorMessageId } from "../../i18n/account-error.ts";
import type {
  ModelSetupReason,
  ModelSetupAction,
  ModelSetupNotice as Notice,
} from "../../workbench/model-setup.ts";

const actionLabels: Record<ModelSetupAction, MessageId> = {
  start: "model_setup.start",
  login: "account.login",
  cancel: "model_setup.cancel_login",
  models: "settings.models",
  choose_model: "account.choose_model",
  refresh: "model_setup.retry",
  schedules: "model_setup.view_schedules",
};

const reasonMessages: Record<ModelSetupReason, MessageId> = {
  persistence: "settings.models_reset_message",
  preparing: "model_setup.preparing",
  execution_unavailable: "model_setup.execution_unavailable",
  checking: "account.checking.title",
  authorizing: "model_setup.authorizing",
  loading: "model_setup.loading",
  account_error: "account.error.generic",
  sign_in: "model_setup.sign_in",
  no_models: "model_setup.no_models",
  catalog_failed: "model_setup.catalog_failed",
  model_unavailable: "model_setup.model_unavailable",
  choose: "model_setup.choose",
  provider_unavailable: "model_setup.provider_unavailable",
  required: "model_setup.required",
  schedule_unavailable: "model_setup.schedule_unavailable",
  schedule_failed: "model_setup.schedule_failed",
  schedule_unknown: "model_setup.schedule_unknown",
  resources_unavailable: "model_setup.resources_unavailable",
};

export function modelSetupMessage(notice: Notice): MessageId {
  return notice.errorCode
    ? accountErrorMessageId(notice.errorCode)
    : reasonMessages[notice.reason];
}

export function ModelSetupNotice({
  notice,
  disabled,
  onAction,
  onChooseSetup,
}: {
  notice: Notice;
  disabled: boolean;
  onAction: (action: ModelSetupAction) => void;
  onChooseSetup?: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="composer-model-notice" role="status">
      <span>{t(modelSetupMessage(notice))}</span>
      {notice.action && (
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={disabled}
          onClick={() => onAction(notice.action!)}
        >
          {t(actionLabels[notice.action])}
        </Button>
      )}
      {onChooseSetup && (
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={disabled}
          onClick={onChooseSetup}
        >
          {t("model_setup.other_options")}
        </Button>
      )}
    </div>
  );
}

export function ModelSetupDialog({
  open,
  customProvidersAvailable,
  returnFocus,
  disabled,
  onClose,
  onLogin,
  onConfigure,
}: {
  open: boolean;
  customProvidersAvailable: boolean;
  returnFocus: RefObject<HTMLElement | null>;
  disabled: boolean;
  onClose: () => void;
  onLogin: () => void;
  onConfigure: () => void;
}) {
  const { t } = useI18n();
  const loginButton = useRef<HTMLButtonElement>(null);
  return (
    <Dialog.Root
      open={open}
      onOpenChange={(next) => {
        if (!next) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup
          className="model-setup-dialog"
          initialFocus={loginButton}
          finalFocus={returnFocus}
        >
          <Dialog.Close
            className="model-setup-close"
            aria-label={t("common.close")}
          >
            <Icon name="close" />
          </Dialog.Close>
          <Dialog.Title>{t("model_setup.title")}</Dialog.Title>
          <Dialog.Description>
            {t(
              customProvidersAvailable
                ? "model_setup.body"
                : "model_setup.body_metask",
            )}
          </Dialog.Description>
          <div className="model-setup-actions">
            <Button
              ref={loginButton}
              type="button"
              size="lg"
              disabled={disabled}
              onClick={onLogin}
            >
              {t("account.login")}
            </Button>
            {customProvidersAvailable && (
              <Button
                type="button"
                variant="secondary"
                size="lg"
                disabled={disabled}
                onClick={onConfigure}
              >
                {t("model_setup.configure")}
              </Button>
            )}
            <Button type="button" variant="ghost" size="md" onClick={onClose}>
              {t("model_setup.skip")}
            </Button>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
