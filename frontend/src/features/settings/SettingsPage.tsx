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
export type SettingsFocusTarget =
  // "providers" focuses the custom-model group within Models.
  "title" | "account" | "models" | "providers" | "archived";
type SettingsSection = "general" | "account" | "models" | "archived";
type RequestedSelection = { selectionId: string; label: string };
type AutomaticWorkspaceRootAction = "choose" | "reset" | "retry";
type AutomaticWorkspaceRootMutationOutcome = "applied" | "cancelled" | false;
function modelLabel(
  model: ModelsView["providers"][number]["models"][number],
  t: ReturnType<typeof useI18n>["t"],
) {
  return model.displayName.trim() || model.id;
}
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
  onRefresh,
  onResetModels,
  onChooseAutomaticWorkspaceRoot,
  onResetAutomaticWorkspaceRoot,
  onRetryAutomaticWorkspaceRoot,
  onCancel,
  onSelectModel,
  onCreateCustomProvider,
  onCreateBuiltinProvider,
  onUpdateCustomProvider,
  onReplaceCustomProviderCredential,
  onAddCustomModel,
  onRemoveCustomModel,
  onReplaceCustomModel,
  onRemoveCustomProvider,
  onTestCustomModel,
  onSelectCustomModel,
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
  onRefresh: () => void;
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
  onSelectModel: (id: string) => void;
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
  const [requestedModel, setRequestedModel] =
    useState<RequestedSelection | null>(null);
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
  const providersHeading = useRef<HTMLHeadingElement>(null);
  const signOut = useRef<HTMLButtonElement>(null);
  const signOutCancel = useRef<HTMLButtonElement>(null);
  const automaticRootChooseButton = useRef<HTMLButtonElement>(null);
  const automaticRootResetButton = useRef<HTMLButtonElement>(null);
  const automaticRootRetryButton = useRef<HTMLButtonElement>(null);
  const automaticRootGeneration = useRef(automaticWorkspaceRoot.generation);
  automaticRootGeneration.current = automaticWorkspaceRoot.generation;
  const metaskProvider = models.providers.find(
    (provider) => provider.id === "metask",
  );
  const metaskModels = metaskProvider?.models ?? [];
  const metaskCatalogState =
    metaskProvider?.catalogState ?? "needs_authentication";
  const selectedModelId = models.metaskSelection?.modelId ?? "";
  const committedProviderId = models.defaultSelection
    ? models.defaultSelection.sourceId === "metask"
      ? "metask"
      : models.defaultSelection.sourceId
    : "";
  const committedCustomProvider = models.customProviders.find(
    (provider) => provider.id === committedProviderId,
  );
  const committedDefaultModel = models.defaultSelection
    ? committedProviderId === "metask"
      ? metaskModels.find(
          (model) => model.id === models.defaultSelection?.modelId,
        )
      : committedCustomProvider?.models.find(
          (model) => model.id === models.defaultSelection?.modelId,
        )
    : null;
  const metaskDefaultUnavailable =
    models.defaultSelection?.sourceId === "metask" &&
    metaskCatalogState === "ready" &&
    !committedDefaultModel;
  const currentDefaultLabel = models.defaultSelection
    ? `${
        committedProviderId === "metask"
          ? "Metask"
          : (committedCustomProvider?.displayName ?? committedProviderId)
      } · ${committedDefaultModel?.displayName || models.defaultSelection.modelId}`
    : t("settings.default_selection_missing");
  const committedModel = metaskModels.find(
    (model) => model.id === selectedModelId,
  );
  const candidateModelId = requestedModel?.selectionId ?? "";
  const candidateModel =
    metaskModels.find((model) => model.id === candidateModelId) ?? null;
  const modelCatalogLoading = models.operation === "refreshing_catalog";
  const modelBusy = modelCatalogLoading;
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
  const modelsPersistenceReady = models.persistenceHealth === "ready";
  const providerIsMetask =
    requestedModel !== null || committedProviderId === "metask";
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
  const modelChoices = useMemo(
    () => [
      ...metaskModels.map((model) => ({
        sourceId: "metask",
        modelId: model.id,
        option: {
          value: JSON.stringify(["metask", model.id]),
          label: modelLabel(model, t),
          disabled:
            accountDisabled ||
            modelBusy ||
            !authenticated ||
            (metaskCatalogState !== "ready" &&
              metaskCatalogState !== "choosing"),
        } as SelectionMenuOption,
      })),
      ...models.customProviders.flatMap((source) =>
        source.models.map((model) => ({
          sourceId: source.id,
          modelId: model.id,
          option: {
            value: JSON.stringify([source.id, model.id]),
            label: model.displayName || model.id,
            disabled:
              !source.enabled ||
              source.state !== "ready" ||
              source.credentialStatus !== "ready" ||
              !model.ready,
          } as SelectionMenuOption,
        })),
      ),
    ],
    [
      metaskModels,
      models.customProviders,
      accountDisabled,
      modelBusy,
      authenticated,
      metaskCatalogState,
      t,
    ],
  );
  const modelOptions = modelChoices.map((choice, index) => ({
    ...choice.option,
    ...(choice.sourceId !== "metask" &&
    (index === 0 || modelChoices[index - 1].sourceId === "metask")
      ? { groupLabel: t("settings.custom_models") }
      : {}),
  }));
  const displayedModelId = requestedModel
    ? JSON.stringify(["metask", requestedModel.selectionId])
    : models.defaultSelection
      ? JSON.stringify([
          models.defaultSelection.sourceId,
          models.defaultSelection.modelId,
        ])
      : "";
  const modelIsOnlyOption =
    modelOptions.length === 1 && modelOptions[0].value === displayedModelId;
  const canChooseModel =
    modelsPersistenceReady && modelOptions.some((option) => !option.disabled);
  const modelPlaceholder =
    modelCatalogLoading && modelOptions.length === 0
      ? t("settings.model_loading")
      : t("account.choose_model");
  const committedModelName =
    (committedModel ? modelLabel(committedModel, t) : "") ||
    selectedModelId ||
    t("account.model_fallback");
  const candidateModelName =
    (candidateModel ? modelLabel(candidateModel, t) : "") ||
    (requestedModel?.selectionId === candidateModelId
      ? requestedModel.label
      : candidateModelId) ||
    t("account.model_fallback");
  const modelHasPendingChange =
    candidateModelId.length > 0 && candidateModelId !== selectedModelId;
  const transactionStatus = (() => {
    if (!providerIsMetask) return null;
    switch (metaskCatalogState) {
      case "needs_authentication":
        return null;
      case "loading":
        if (modelHasPendingChange) {
          return {
            title: t("settings.switch.preparing_model", {
              model: candidateModelName,
            }),
            detail: t("settings.switch.current_model_preserved", {
              model: committedModelName,
            }),
          };
        }
        return {
          title: t("settings.loading_models"),
          detail: t("settings.switch.refreshing"),
        };
      case "choosing":
        return {
          title: t("account.choose_model"),
          detail: t("settings.default_model_help"),
        };
      case "unavailable":
      case "ready":
      case "failed":
        return null;
    }
  })();
  useEffect(() => {
    if (focusTarget === "archived") {
      setActiveSection("archived");
    } else if (focusTarget === "providers" && customProviderSettingsAvailable) {
      setActiveSection("models");
    } else if (focusTarget === "models") {
      setActiveSection("models");
    } else if (focusTarget === "account") {
      setActiveSection("account");
    }
  }, [focusTarget, customProviderSettingsAvailable]);
  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      if (activeSection === "general" && focusTarget === "title") {
        generalHeading.current?.focus();
      } else if (activeSection === "account") {
        accountHeading.current?.focus();
      } else if (activeSection === "models") {
        if (customProviderSettingsAvailable && focusTarget === "providers") {
          providersHeading.current?.focus();
        } else {
          modelsHeading.current?.focus();
        }
      }
    });
    return () => window.cancelAnimationFrame(frame);
  }, [activeSection, focusTarget, customProviderSettingsAvailable]);
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
  useEffect(() => {
    if (
      models.errorCode !== "none" ||
      account.state !== "authenticated" ||
      (metaskCatalogState === "ready" && !disabled)
    ) {
      setRequestedModel(null);
    }
  }, [
    models.errorCode,
    metaskCatalogState,
    models.metaskSelection,
    account.state,
    disabled,
  ]);
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

              <div className="settings-group">
                <h3
                  id="settings-execution-title"
                  className="settings-group-label"
                >
                  {t("settings.default_model_for_new_tasks")}
                </h3>
                <div
                  className="settings-execution-group"
                  role="group"
                  aria-labelledby="settings-execution-title"
                >
                  <div className="settings-execution-header">
                    <span className="settings-current-default">
                      <span>{t("settings.current_default")}</span>
                      <strong>{currentDefaultLabel}</strong>
                    </span>
                    <div className="settings-execution-actions">
                      <span className="settings-catalog-count">
                        {t("settings.catalog_count", {
                          models: modelChoices.length,
                        })}
                      </span>
                      <button
                        className="settings-refresh-button focus-ring"
                        disabled={
                          disabled ||
                          accountDisabled ||
                          !authenticated ||
                          modelBusy
                        }
                        onClick={onRefresh}
                      >
                        <Icon name="refresh" />
                        {t("account.refresh_catalog")}
                      </button>
                    </div>
                  </div>

                  <div className="settings-field">
                    <div className="settings-field-copy">
                      <label htmlFor="settings-model">
                        {t("settings.default_model")}
                      </label>
                      <p>
                        {t(
                          modelIsOnlyOption
                            ? "settings.only_model_help"
                            : "settings.default_model_help",
                        )}
                      </p>
                    </div>
                    <div className="settings-control-stack">
                      <SelectionMenu
                        triggerId="settings-model"
                        value={displayedModelId}
                        options={modelOptions}
                        placeholder={modelPlaceholder}
                        ariaLabel={t("settings.default_model")}
                        helper={t("settings.model_menu_help")}
                        actionLabel={t(
                          modelIsOnlyOption
                            ? "settings.view_selection"
                            : displayedModelId
                              ? "settings.change_selection"
                              : "settings.choose_selection",
                        )}
                        disabled={
                          disabled ||
                          executionDisabled ||
                          !canChooseModel ||
                          modelOptions.length === 0
                        }
                        busy={providerIsMetask && modelBusy}
                        leading={<Icon name="model" />}
                        triggerClassName="settings-control"
                        contentClassName="settings-selection-menu"
                        onValueChange={(value) => {
                          const choice = modelChoices.find(
                            (item) => item.option.value === value,
                          );
                          if (!choice || choice.option.disabled) return;
                          if (choice.sourceId !== "metask") {
                            const source = models.customProviders.find(
                              (item) => item.id === choice.sourceId,
                            );
                            if (!source) return;
                            setRequestedModel(null);
                            onSelectCustomModel(
                              source.id,
                              source.providerRevision,
                              choice.modelId,
                            );
                            return;
                          }
                          const model = metaskModels.find(
                            (candidate) => candidate.id === choice.modelId,
                          );
                          if (!model) return;
                          setRequestedModel({
                            selectionId: model.id,
                            label: modelLabel(model, t),
                          });
                          onSelectModel(model.id);
                        }}
                      />
                      {providerIsMetask && modelHasPendingChange && (
                        <span className="settings-pending-label">
                          <span aria-hidden="true" />
                          {t("settings.switch.pending_label")}
                        </span>
                      )}
                    </div>
                  </div>

                  {transactionStatus && (
                    <div
                      className="settings-operation"
                      role="status"
                      aria-live="polite"
                    >
                      <span
                        className="settings-operation-dot"
                        aria-hidden="true"
                      />
                      <span className="settings-operation-copy">
                        <strong>{transactionStatus.title}</strong>
                        <span>{transactionStatus.detail}</span>
                      </span>
                    </div>
                  )}
                </div>

                <p className="settings-binding-note">
                  <Icon name="check" />
                  {t("settings.existing_tasks_unchanged")}
                </p>

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

                {((models.errorCode !== "none" &&
                  models.errorCode !== "authorization_unavailable") ||
                  metaskDefaultUnavailable) && (
                  <div className="settings-error" role="alert">
                    <Icon name="warning" />
                    <span className="settings-error-copy">
                      <strong>{t("settings.models_error")}</strong>
                      <span>
                        {t(
                          models.errorCode === "no_models"
                            ? "account.error.no_models"
                            : metaskDefaultUnavailable
                              ? "settings.default_model_unavailable"
                              : "settings.models_error_help",
                        )}
                      </span>
                    </span>
                  </div>
                )}
              </div>
            </section>
          )}
          {activeSection === "models" && customProviderSettingsAvailable && (
            <CustomModelsSettings
              models={models}
              disabled={disabled || executionDisabled}
              headingRef={providersHeading}
              onCreateCustomProvider={onCreateCustomProvider}
              onCreateBuiltinProvider={onCreateBuiltinProvider}
              onUpdateCustomProvider={onUpdateCustomProvider}
              onReplaceCustomProviderCredential={
                onReplaceCustomProviderCredential
              }
              onAddCustomModel={onAddCustomModel}
              onReplaceCustomModel={onReplaceCustomModel}
              onRemoveCustomModel={onRemoveCustomModel}
              onRemoveCustomProvider={onRemoveCustomProvider}
              onTestCustomModel={onTestCustomModel}
              onSelectCustomModel={onSelectCustomModel}
            />
          )}
        </div>
      </div>
    </div>
  );
}
