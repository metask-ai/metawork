import { useEffect, useMemo, useRef, useState } from "react";
import type {
  AccountView,
  ModelsView,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { ConfirmationNotice } from "../../components/ConfirmationNotice.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { useI18n, type Locale, type MessageId } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";
import {
  accountIdentityInitial,
  accountIdentityLabel,
} from "../../workbench/account-identity.ts";
import { AccountBalance, AccountUsageSummary } from "./AccountUsageSummary.tsx";
import { ArchivedTasks, type ArchivedTasksProps } from "./ArchivedTasks.tsx";
import {
  CustomModelsSettings,
  type CustomModelActions,
} from "./CustomModelsSettings.tsx";
import { supportsCustomProviders } from "../../workbench/model-setup.ts";
export type SettingsFocusTarget = "title" | "account" | "models" | "archived";

type SettingsSection = "general" | "account" | "models" | "archived";
type AutomaticWorkspaceRootAction = "choose" | "reset" | "retry";
type AutomaticWorkspaceRootMutationOutcome = "applied" | "cancelled" | false;
export function SettingsPage({
  archiveManagement,
  account,
  models,
  automaticWorkspaceRoot,
  customProviderCapabilities,
  focusTarget,
  initialSection = "general",
  disabled,
  accountDisabled,
  executionDisabled,
  cancelDisabled,
  onBack,
  onResetModels,
  onChooseAutomaticWorkspaceRoot,
  onResetAutomaticWorkspaceRoot,
  onRetryAutomaticWorkspaceRoot,
  onCancel,
  onCreateCustomProvider,
  onCreateBuiltinProvider,
  onUpdateCustomProvider,
  onReplaceCustomProviderCredential,
  onAddCustomModel,
  onRemoveCustomModel,
  onReplaceCustomModel,
  onTestCustomModel,
  onBeginLogin,
  onRetryRefresh,
  onRefreshAccountSummary,
  onOpenRecharge,
  onLogout,
}: {
  archiveManagement?: ArchivedTasksProps;
  account: AccountView;
  models: ModelsView;
  automaticWorkspaceRoot: WorkbenchSnapshot["automaticWorkspaceRoot"];
  customProviderCapabilities: {
    management: boolean;
    secretCapture: boolean;
    modelTest: boolean;
  };
  focusTarget: SettingsFocusTarget;
  initialSection?: SettingsSection;
  disabled: boolean;
  accountDisabled: boolean;
  executionDisabled: boolean;
  cancelDisabled: boolean;
  onBack: () => void;
  onResetModels: () => Promise<boolean>;
  onChooseAutomaticWorkspaceRoot: (
    expectedGeneration: string,
  ) => Promise<AutomaticWorkspaceRootMutationOutcome>;
  onResetAutomaticWorkspaceRoot: (
    expectedGeneration: string,
  ) => Promise<AutomaticWorkspaceRootMutationOutcome>;
  onRetryAutomaticWorkspaceRoot: (
    expectedGeneration: string,
  ) => Promise<AutomaticWorkspaceRootMutationOutcome>;
  onCancel: () => void;
  onBeginLogin: () => void;
  onRetryRefresh: () => void;
  onRefreshAccountSummary: () => void;
  onOpenRecharge: () => void;
  onLogout: () => void;
} & CustomModelActions) {
  const { locale, setLocale, t } = useI18n();
  const customProviderSettingsAvailable = supportsCustomProviders(
    customProviderCapabilities,
  );
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const [activeSection, setActiveSection] =
    useState<SettingsSection>(initialSection);
  const [automaticRootPending, setAutomaticRootPending] = useState<{
    action: AutomaticWorkspaceRootAction;
    generation: string;
  } | null>(null);
  const [automaticRootMutationFailed, setAutomaticRootMutationFailed] =
    useState(false);
  const content = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const generalHeading = useRef<HTMLHeadingElement>(null);
  const accountHeading = useRef<HTMLHeadingElement>(null);
  const modelsHeading = useRef<HTMLHeadingElement>(null);
  const signOut = useRef<HTMLButtonElement>(null);
  const signOutCancel = useRef<HTMLButtonElement>(null);
  const automaticRootChooseButton = useRef<HTMLButtonElement>(null);
  const automaticRootResetButton = useRef<HTMLButtonElement>(null);
  const automaticRootRetryButton = useRef<HTMLButtonElement>(null);
  const automaticRootGeneration = useRef(automaticWorkspaceRoot.generation);
  automaticRootGeneration.current = automaticWorkspaceRoot.generation;
  const authenticated = account.state === "authenticated";
  const accountIdentityTitle = authenticated
    ? accountIdentityLabel(account, t("account.signed_in"))
    : account.state === "checking"
      ? t("account.checking.title")
      : account.state === "authorizing"
        ? t("account.authorizing.title")
        : t("account.sign_in_required.title");
  const accountIdentityBody =
    account.state === "checking"
      ? t("account.checking.body")
      : account.state === "authorizing"
        ? t("account.authorizing.body")
        : t("account.sign_in_required.body");
  const languageOptions = useMemo<SelectionMenuOption[]>(
    () => [
      { value: "en-US", label: t("app.language.en-US") },
      { value: "zh-CN", label: t("app.language.zh-CN") },
      ...(import.meta.env.DEV
        ? [{ value: "pseudo", label: t("app.language.pseudo") }]
        : []),
    ],
    [t],
  );
  useEffect(() => {
    if (focusTarget === "archived") {
      setActiveSection("archived");
    } else if (focusTarget === "models") {
      setActiveSection("models");
    } else if (focusTarget === "account") {
      setActiveSection("account");
    }
  }, [focusTarget]);
  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      if (activeSection === "general" && focusTarget === "title") {
        generalHeading.current?.focus();
      } else if (activeSection === "account") {
        accountHeading.current?.focus();
      } else if (activeSection === "models") {
        modelsHeading.current?.focus();
      }
    });
    return () => window.cancelAnimationFrame(frame);
  }, [activeSection, focusTarget]);
  useEffect(() => {
    if (activeSection === "archived" && content.current)
      content.current.scrollTop = archiveManagement?.scrollTop ?? 0;
    else content.current?.scrollTo?.({ top: 0, behavior: "auto" });
  }, [activeSection]);
  useEffect(() => {
    if (!confirmSignOut) return;
    const frame = window.requestAnimationFrame(() =>
      signOutCancel.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [confirmSignOut]);
  useEffect(() => {
    if (
      !automaticRootPending ||
      automaticRootPending.generation === automaticWorkspaceRoot.generation
    )
      return;
    const action = automaticRootPending.action;
    setAutomaticRootPending(null);
    setAutomaticRootMutationFailed(false);
    restoreAutomaticRootFocus(action);
  }, [automaticWorkspaceRoot.generation, automaticRootPending]);
  function restoreAutomaticRootFocus(action: AutomaticWorkspaceRootAction) {
    const origin =
      action === "choose"
        ? automaticRootChooseButton
        : action === "reset"
          ? automaticRootResetButton
          : automaticRootRetryButton;
    window.requestAnimationFrame(() =>
      (
        origin.current ??
        automaticRootChooseButton.current ??
        automaticRootResetButton.current ??
        automaticRootRetryButton.current
      )?.focus(),
    );
  }
  async function mutateAutomaticWorkspaceRoot(
    action: AutomaticWorkspaceRootAction,
  ) {
    if (automaticRootPending) return;
    const generation = automaticWorkspaceRoot.generation;
    setAutomaticRootMutationFailed(false);
    setAutomaticRootPending({ action, generation });
    const invoke =
      action === "choose"
        ? onChooseAutomaticWorkspaceRoot
        : action === "reset"
          ? onResetAutomaticWorkspaceRoot
          : onRetryAutomaticWorkspaceRoot;
    let outcome: AutomaticWorkspaceRootMutationOutcome;
    try {
      outcome = await invoke(generation);
    } catch {
      outcome = false;
    }
    // A canonical refresh can win the race with a lost/late command result.
    // Once generation advances, that Snapshot is authoritative for both the
    // value and the action state; never paint a stale local failure over it.
    if (automaticRootGeneration.current !== generation) return;
    if (outcome === "applied") return;
    setAutomaticRootPending(null);
    setAutomaticRootMutationFailed(outcome === false);
    restoreAutomaticRootFocus(action);
  }
  const automaticRootDisplay =
    automaticWorkspaceRoot.canonicalRoot ??
    t("settings.automatic_workspace.location_unavailable");
  const automaticRootHasAttention = automaticWorkspaceRoot.health !== "ready";
  const automaticRootHealthMessage: MessageId =
    automaticWorkspaceRoot.health === "write_failed" &&
    automaticWorkspaceRoot.canonicalRoot === null
      ? "settings.automatic_workspace.health.write_failed_no_active"
      : `settings.automatic_workspace.health.${automaticWorkspaceRoot.health}`;
  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
  }
  return (
    <div
      className="settings-page"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-page-title"
      tabIndex={-1}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        const nestedOverlay = (event.target as HTMLElement).closest(
          '[role="menu"], [role="listbox"], [role="dialog"], [role="alertdialog"]',
        );
        if (nestedOverlay && nestedOverlay !== event.currentTarget) return;
        event.preventDefault();
        onBack();
      }}
    >
      <header className="settings-header">
        <div className="settings-back-slot">
          <button className="settings-back focus-ring" onClick={onBack}>
            <Icon name="arrow-left" />
            {t("settings.back")}
          </button>
        </div>
      </header>

      <div className="settings-layout">
        <nav className="settings-nav" aria-label={t("settings.sections")}>
          <a
            className="focus-ring"
            href="#settings-general"
            aria-current={activeSection === "general" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("general");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="settings" />
            </span>
            <span>{t("settings.general")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-account"
            aria-current={activeSection === "account" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("account");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="account" />
            </span>
            <span>{t("settings.account")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-models"
            aria-current={activeSection === "models" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("models");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="model" />
            </span>
            <span>{t("settings.models")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-archived"
            aria-current={activeSection === "archived" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("archived");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="archive" />
            </span>
            <span>{t("settings.archived_tasks")}</span>
          </a>
        </nav>

        <div
          ref={content}
          className="settings-content"
          onScroll={(event) => {
            if (activeSection === "archived")
              archiveManagement?.onScroll?.(event.currentTarget.scrollTop);
          }}
        >
          <h1
            id="settings-page-title"
            ref={title}
            className="sr-only"
            tabIndex={-1}
          >
            {t("settings.title")}
          </h1>
          {activeSection === "archived" && archiveManagement && (
            <ArchivedTasks {...archiveManagement} />
          )}
          {activeSection === "general" && (
            <section id="settings-general" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={generalHeading} tabIndex={-1}>
                  {t("settings.general")}
                </h2>
              </div>
              <div className="settings-group">
                <h3 className="settings-group-label">
                  {t("settings.general_basics")}
                </h3>
                <div className="settings-preference-list">
                  <div className="settings-row">
                    <div>
                      <label htmlFor="settings-language">
                        {t("app.language")}
                      </label>
                      <p>{t("settings.language_help")}</p>
                    </div>
                    <SelectionMenu
                      triggerId="settings-language"
                      value={locale}
                      options={languageOptions}
                      placeholder={t("app.language")}
                      ariaLabel={t("app.language")}
                      disabled={false}
                      triggerClassName="settings-control settings-control-compact"
                      onValueChange={(value) => setLocale(value as Locale)}
                    />
                  </div>
                  <div className="settings-row settings-automatic-root-row">
                    <div className="settings-automatic-root-copy">
                      <span className="settings-row-label">
                        {t("settings.automatic_workspace.title")}
                      </span>
                      <p>{t("settings.automatic_workspace.help")}</p>
                      <div className="settings-automatic-root-value">
                        <code
                          className="settings-automatic-root-location"
                          title={automaticRootDisplay}
                        >
                          {automaticRootDisplay}
                        </code>
                        {automaticWorkspaceRoot.mode === "system_default" ? (
                          <span className="settings-automatic-root-default">
                            {t("settings.automatic_workspace.system_default")}
                          </span>
                        ) : null}
                      </div>
                      {automaticRootHasAttention ? (
                        <p
                          className="settings-automatic-root-health"
                          role="status"
                        >
                          {t(automaticRootHealthMessage)}
                        </p>
                      ) : null}
                      {automaticRootMutationFailed &&
                      !automaticRootHasAttention ? (
                        <p
                          className="settings-automatic-root-error"
                          role="alert"
                        >
                          {t("settings.automatic_workspace.command_failed")}
                        </p>
                      ) : null}
                    </div>
                    <div className="settings-automatic-root-actions">
                      {automaticWorkspaceRoot.canChoose ? (
                        <Button
                          ref={automaticRootChooseButton}
                          variant="secondary"
                          size="sm"
                          disabled={disabled || automaticRootPending !== null}
                          onClick={() =>
                            void mutateAutomaticWorkspaceRoot("choose")
                          }
                        >
                          {automaticRootPending?.action === "choose"
                            ? t("settings.automatic_workspace.choosing")
                            : t("settings.automatic_workspace.choose")}
                        </Button>
                      ) : null}
                      {automaticWorkspaceRoot.canReset ? (
                        <Button
                          ref={automaticRootResetButton}
                          variant="secondary"
                          size="sm"
                          disabled={disabled || automaticRootPending !== null}
                          onClick={() =>
                            void mutateAutomaticWorkspaceRoot("reset")
                          }
                        >
                          {automaticRootPending?.action === "reset"
                            ? t("settings.automatic_workspace.resetting")
                            : t("settings.automatic_workspace.reset")}
                        </Button>
                      ) : null}
                      {automaticWorkspaceRoot.canRetry ? (
                        <Button
                          ref={automaticRootRetryButton}
                          variant="secondary"
                          size="sm"
                          disabled={disabled || automaticRootPending !== null}
                          onClick={() =>
                            void mutateAutomaticWorkspaceRoot("retry")
                          }
                        >
                          {automaticRootPending?.action === "retry"
                            ? t("settings.automatic_workspace.retrying")
                            : t("settings.automatic_workspace.retry")}
                        </Button>
                      ) : null}
                    </div>
                  </div>
                </div>
              </div>
            </section>
          )}

          {activeSection === "account" && (
            <section id="settings-account" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={accountHeading} tabIndex={-1}>
                  {t("settings.account")}
                </h2>
              </div>

              <div className="settings-group">
                <h3 className="settings-group-label">
                  {t("settings.account_profile")}
                </h3>
                <div
                  className="settings-identity-row"
                  data-session-state={account.state}
                >
                  <span className="settings-avatar" aria-hidden="true">
                    {accountIdentityInitial(account)}
                  </span>
                  <div className="settings-identity-copy">
                    <strong title={accountIdentityTitle}>
                      {accountIdentityTitle}
                    </strong>
                    {authenticated ? (
                      <div className="settings-identity-meta">
                        {account.emailHint &&
                        account.emailHint !== accountIdentityTitle ? (
                          <span title={account.emailHint}>
                            {account.emailHint}
                          </span>
                        ) : null}
                        {account.phoneHint &&
                        account.phoneHint !== accountIdentityTitle ? (
                          <span title={account.phoneHint}>
                            {account.phoneHint}
                          </span>
                        ) : null}
                        <span>
                          {t("settings.account_concurrency_limit", {
                            value:
                              account.concurrencyLimit === 0
                                ? t("settings.account_concurrency_unlimited")
                                : (account.concurrencyLimit ?? "—"),
                          })}
                        </span>
                      </div>
                    ) : (
                      <span>{accountIdentityBody}</span>
                    )}
                  </div>
                  {authenticated &&
                  account.summary.usageEligibility !== "disabled" ? (
                    <AccountBalance
                      wallet={account.summary.wallet}
                      disabled={disabled || accountDisabled}
                      onRecharge={onOpenRecharge}
                    />
                  ) : null}
                  {account.canCancel ? (
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={cancelDisabled}
                      onClick={onCancel}
                    >
                      {t("common.cancel")}
                    </Button>
                  ) : !authenticated ||
                    (account.errorCode !== "none" &&
                      account.errorCode !== "refresh_schedule_failed") ? (
                    <Button
                      className="settings-identity-login"
                      variant="secondary"
                      size="sm"
                      disabled={disabled || accountDisabled}
                      onClick={onBeginLogin}
                    >
                      {t("account.login")}
                    </Button>
                  ) : null}
                </div>
              </div>

              {account.errorCode !== "none" &&
                account.errorCode !== "user_cancelled" && (
                  <div className="settings-error" role="alert">
                    <Icon name="warning" />
                    <span className="settings-error-copy">
                      <strong>{t("account.action_failed")}</strong>
                      <span>{accountErrorText(account.errorCode, t)}</span>
                      {account.safeDiagnostic && (
                        <span className="settings-error-diagnostic">
                          {account.safeDiagnostic}
                        </span>
                      )}
                    </span>
                    {account.errorCode === "refresh_schedule_failed" && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={disabled || accountDisabled}
                        onClick={onRetryRefresh}
                      >
                        {t("account.retry_refresh")}
                      </Button>
                    )}
                  </div>
                )}

              {authenticated && (
                <AccountUsageSummary
                  summary={account.summary}
                  disabled={disabled || accountDisabled}
                  onRefresh={onRefreshAccountSummary}
                />
              )}

              {authenticated && (
                <div className="settings-group">
                  <h3 className="settings-group-label">
                    {t("settings.account_security")}
                  </h3>
                  <div className="settings-danger-zone">
                    <div>
                      <h3 id="settings-signout-title">
                        {t("settings.signout_title")}
                      </h3>
                      <p>{t("settings.signout_help")}</p>
                    </div>
                    {!confirmSignOut ? (
                      <Button
                        variant="danger"
                        size="sm"
                        ref={signOut}
                        disabled={disabled || accountDisabled}
                        onClick={() => setConfirmSignOut(true)}
                      >
                        {t("account.logout_short")}
                      </Button>
                    ) : (
                      <div
                        className="settings-signout-confirmation"
                        role="group"
                        aria-labelledby="settings-signout-title"
                        aria-describedby="settings-signout-confirmation-copy"
                        onKeyDown={(event) => {
                          if (event.key !== "Escape") return;
                          event.preventDefault();
                          closeSignOutConfirmation();
                        }}
                      >
                        <p id="settings-signout-confirmation-copy">
                          {t("account.logout_confirm")}
                        </p>
                        <span>
                          <Button
                            variant="secondary"
                            size="sm"
                            ref={signOutCancel}
                            onClick={closeSignOutConfirmation}
                          >
                            {t("common.cancel")}
                          </Button>
                          <Button
                            variant="danger"
                            size="sm"
                            disabled={disabled || accountDisabled}
                            onClick={onLogout}
                          >
                            {t("account.logout")}
                          </Button>
                        </span>
                      </div>
                    )}
                  </div>
                </div>
              )}
            </section>
          )}

          {activeSection === "models" && (
            <section id="settings-models" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={modelsHeading} tabIndex={-1}>
                  {t("settings.models")}
                </h2>
              </div>
              {models.persistenceHealth === "recovery_required" && (
                <ConfirmationNotice
                  className="task-persistence-error settings-model-reset-notice"
                  message={t("settings.models_reset_message")}
                  detail={t("settings.models_reset_detail")}
                  actionLabel={t("settings.models_reset_action")}
                  dialogTitle={t("settings.models_reset_dialog_title")}
                  dialogDescription={t("settings.models_reset_dialog_body")}
                  cancelLabel={t("common.cancel")}
                  confirmLabel={t("settings.models_reset_confirm")}
                  pendingLabel={t("settings.models_reset_pending")}
                  failureMessage={t("settings.models_reset_failed")}
                  actionAvailable
                  disabled={disabled || executionDisabled}
                  onConfirm={async () =>
                    (await onResetModels())
                      ? null
                      : t("settings.models_reset_failed")
                  }
                />
              )}
              {customProviderSettingsAvailable && (
                <CustomModelsSettings
                  models={models}
                  disabled={disabled || executionDisabled}
                  onCreateCustomProvider={onCreateCustomProvider}
                  onCreateBuiltinProvider={onCreateBuiltinProvider}
                  onUpdateCustomProvider={onUpdateCustomProvider}
                  onReplaceCustomProviderCredential={
                    onReplaceCustomProviderCredential
                  }
                  onAddCustomModel={onAddCustomModel}
                  onReplaceCustomModel={onReplaceCustomModel}
                  onRemoveCustomModel={onRemoveCustomModel}
                  onTestCustomModel={onTestCustomModel}
                />
              )}
            </section>
          )}
        </div>
      </div>
    </div>
  );
}
