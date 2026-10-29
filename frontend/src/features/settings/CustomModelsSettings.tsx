import { useEffect, useRef, useState } from "react";
import type {
  BuiltinProviderId,
  CustomProviderView,
  ModelsView,
  Protocol,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Badge } from "../../components/ui/badge.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { useI18n } from "../../i18n/context.ts";

import {
  customProviderEndpointFromBaseUrl,
  customProviderBaseUrl,
  providerRequestPaths,
} from "./model-connection.ts";

function ModelAction({
  label,
  icon,
  disabled,
  loading = false,
  onClick,
}: {
  label: string;
  icon: "test" | "edit" | "trash";
  disabled: boolean;
  loading?: boolean;
  onClick: () => void;
}) {
  return (
    <Tooltip.Root>
      <Tooltip.Trigger
        render={
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="size-11 text-base"
            aria-label={label}
            aria-busy={loading || undefined}
            disabled={disabled}
            onClick={onClick}
          />
        }
      >
        <span
          className={
            loading
              ? "inline-flex animate-spin motion-reduce:animate-none"
              : "inline-flex"
          }
        >
          <Icon name={loading ? "loading" : icon} />
        </span>
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Positioner side="top" className="z-[60]">
          <Tooltip.Popup>{label}</Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

const examples: Record<Protocol, string> = {
  openai_responses: "https://api.openai.com/v1",
  openai_chat_completions: "https://api.openai.com/v1",
  anthropic_messages: "https://api.anthropic.com",
  gemini_native: "https://generativelanguage.googleapis.com",
};
export type CustomModelActions = {
  onCreateCustomProvider: (input: {
    displayName: string;
    protocol: Protocol;
    normalizedBaseUrl: string;
    apiKey: string;
    model: { id: string };
  }) => Promise<boolean>;
  onCreateBuiltinProvider: (input: {
    providerId: BuiltinProviderId;
    baseUrl: string;
    apiKey: string;
    model: { id: string };
  }) => Promise<boolean>;
  onUpdateCustomProvider: (input: {
    providerId: string;
    expectedProviderRevision: string;
    displayName: string;
    protocol: Protocol;
    normalizedBaseUrl: string;
  }) => Promise<boolean>;
  onReplaceCustomProviderCredential: (
    providerId: string,
    revision: string,
    apiKey: string,
  ) => Promise<boolean>;
  onReplaceCustomModel: (
    providerId: string,
    revision: string,
    catalogGeneration: string,
    modelId: string,
    replacementId: string,
  ) => Promise<boolean>;
  onRemoveCustomModel: (
    providerId: string,
    revision: string,
    catalogGeneration: string,
    modelId: string,
  ) => Promise<boolean>;
  onTestCustomModel: (
    providerId: string,
    revision: string,
    modelId: string,
    sourceGeneration: string,
    catalogGeneration: string,
  ) => void;
};
type Draft = {
  choice: string;
  modelId: string;
  originalModelId: string | null;
  providerId: string | null;
  revision: string | null;
  catalogGeneration: string | null;
  protocol: Protocol;
  baseUrl: string;
  apiKey: string;
};
const emptyDraft = (): Draft => ({
  choice: "",
  modelId: "",
  originalModelId: null,
  providerId: null,
  revision: null,
  catalogGeneration: null,
  protocol: "openai_chat_completions",
  baseUrl: "",
  apiKey: "",
});

export function CustomModelsSettings({
  models,
  disabled,
  ...actions
}: CustomModelActions & {
  models: ModelsView;
  disabled: boolean;
}) {
  const { t } = useI18n();
  const [draft, setDraft] = useState<Draft | null>(null);
  const [pending, setPending] = useState(false);
  const [removal, setRemoval] = useState<{
    source: CustomProviderView;
    modelId: string;
  } | null>(null);
  const [failed, setFailed] = useState(false);
  const dialogVersion = useRef(0);
  const addButton = useRef<HTMLButtonElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const provider = models.customProviders.find(
    (item) => item.id === draft?.providerId,
  );
  const preset = models.builtinProviderPresets.find(
    (item) =>
      draft?.choice === `preset:${item.id}` ||
      provider?.builtinProviderId === item.id,
  );
  const editing =
    draft?.originalModelId !== null && draft?.originalModelId !== undefined;
  const busy = disabled || pending;
  const rows = models.customProviders.flatMap((source) =>
    source.models.map((model) => ({ source, model })),
  );
  function close() {
    dialogVersion.current += 1;
    setDraft(null);
    setFailed(false);
  }
  function open(source?: CustomProviderView, modelId: string | null = null) {
    returnFocus.current =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : addButton.current;
    dialogVersion.current += 1;
    setFailed(false);
    setDraft(
      source
        ? {
            ...emptyDraft(),
            choice: source.builtinProviderId
              ? `preset:${source.builtinProviderId}`
              : "custom",
            providerId: source.id,
            revision: source.providerRevision,
            catalogGeneration: source.catalogGeneration,
            protocol: source.protocol,
            baseUrl: customProviderBaseUrl(source),
            modelId: modelId ?? "",
            originalModelId: modelId,
          }
        : emptyDraft(),
    );
  }
  useEffect(() => {
    if (!draft?.providerId) return;
    const current = models.customProviders.find(
      (item) => item.id === draft.providerId,
    );
    if (
      !current ||
      current.providerRevision !== draft.revision ||
      current.catalogGeneration !== draft.catalogGeneration
    )
      close();
  }, [
    models.customProviders,
    draft?.providerId,
    draft?.revision,
    draft?.catalogGeneration,
  ]);
  function choose(value: string) {
    const recipe = models.builtinProviderPresets.find(
      (item) => value === `preset:${item.id}`,
    );
    setFailed(false);
    setDraft({
      ...emptyDraft(),
      choice: value,
      protocol: recipe?.protocol ?? "openai_chat_completions",
      baseUrl: recipe?.defaultBaseUrl ?? "",
    });
  }
  async function perform(operation: () => Promise<boolean>) {
    if (busy) return;
    const version = dialogVersion.current;
    setPending(true);
    setFailed(false);
    try {
      const success = await operation();
      if (version === dialogVersion.current) {
        if (success) close();
        else {
          setDraft((current) => (current ? { ...current, apiKey: "" } : null));
          setFailed(true);
        }
      }
    } catch {
      if (version === dialogVersion.current) {
        setDraft((current) => (current ? { ...current, apiKey: "" } : null));
        setFailed(true);
      }
    } finally {
      setPending(false);
    }
  }
  async function submit() {
    if (!draft || !draft.modelId.trim()) return;
    const modelId = draft.modelId.trim();
    if (editing && modelId === draft.originalModelId) return;
    if (provider && editing) {
      await perform(() =>
        actions.onReplaceCustomModel(
          provider.id,
          provider.providerRevision,
          provider.catalogGeneration,
          draft.originalModelId!,
          modelId,
        ),
      );
    } else if (preset) {
      await perform(() =>
        actions.onCreateBuiltinProvider({
          providerId: preset.id,
          baseUrl: preset.defaultBaseUrl,
          apiKey: draft.apiKey,
          model: { id: modelId },
        }),
      );
    } else if (draft.choice === "custom") {
      let name: string;
      try {
        name = new URL(draft.baseUrl.trim()).host;
      } catch {
        setDraft({ ...draft, apiKey: "" });
        setFailed(true);
        return;
      }
      await perform(() =>
        actions.onCreateCustomProvider({
          displayName: name,
          protocol: draft.protocol,
          normalizedBaseUrl: customProviderEndpointFromBaseUrl(
            draft.protocol,
            draft.baseUrl,
          ),
          apiKey: draft.apiKey,
          model: { id: modelId },
        }),
      );
    }
  }
  const choiceOptions = [
    ...models.builtinProviderPresets.map((recipe) => ({
      value: `preset:${recipe.id}`,
      label: recipe.displayName,
    })),
    { value: "custom", label: t("settings.model_connection_custom") },
  ];
  async function remove() {
    if (!removal || busy) return;
    const { source, modelId } = removal;
    setPending(true);
    setFailed(false);
    try {
      const success = await actions.onRemoveCustomModel(
        source.id,
        source.providerRevision,
        source.catalogGeneration,
        modelId,
      );
      if (success) setRemoval(null);
      else setFailed(true);
    } catch {
      setFailed(true);
    } finally {
      setPending(false);
    }
  }
  return (
    <section
      className="settings-group settings-model-services"
      id="settings-custom-models"
      aria-labelledby="settings-custom-models-title"
    >
      <div className="settings-model-list-heading">
        <div>
          <h3
            className="settings-group-label"
            id="settings-custom-models-title"
          >
            {t("settings.custom_models")}
          </h3>
          <p>{t("settings.model_connection_help")}</p>
        </div>
        <Button
          size="sm"
          ref={addButton}
          disabled={busy}
          onClick={() => open()}
        >
          <Icon name="plus" />
          {t("settings.custom_model_add")}
        </Button>
      </div>
      <div className="settings-model-list">
        {rows.map(({ source, model }) => (
          <div
            className="settings-model-row"
            key={JSON.stringify([source.id, model.id])}
          >
            <div className="settings-model-identity">
              <strong>{model.displayName || model.id}</strong>
              <Badge className="shrink-0 whitespace-nowrap">
                {t(`settings.custom_model_test_status.${model.testStatus}`)}
              </Badge>
            </div>
            <div className="settings-custom-provider-actions">
              <ModelAction
                icon="test"
                label={t(
                  model.testStatus === "testing"
                    ? "settings.custom_model_testing"
                    : "settings.custom_model_test",
                )}
                loading={model.testStatus === "testing"}
                disabled={
                  busy ||
                  !source.enabled ||
                  source.credentialStatus !== "ready" ||
                  model.testStatus === "testing"
                }
                onClick={() =>
                  actions.onTestCustomModel(
                    source.id,
                    source.providerRevision,
                    model.id,
                    source.sourceGeneration,
                    source.catalogGeneration,
                  )
                }
              />
              <ModelAction
                icon="edit"
                label={t("common.edit")}
                disabled={busy}
                onClick={() => open(source, model.id)}
              />
              <ModelAction
                label={t("common.remove")}
                icon="trash"
                disabled={busy}
                onClick={() => {
                  setFailed(false);
                  setRemoval({ source, modelId: model.id });
                }}
              />
            </div>
          </div>
        ))}
        {rows.length === 0 && (
          <p className="settings-model-list-empty">
            {t("settings.model_connection_empty")}
          </p>
        )}
      </div>
      <Dialog.Root
        open={draft !== null}
        onOpenChange={(open) => {
          if (!open && !pending) close();
        }}
      >
        {draft && (
          <Dialog.Portal>
            <Dialog.Backdrop className="settings-model-dialog-backdrop" />
            <Dialog.Popup
              className="settings-model-dialog"
              finalFocus={() =>
                returnFocus.current?.isConnected
                  ? returnFocus.current
                  : addButton.current
              }
            >
              <Dialog.Title>
                {t(
                  editing
                    ? "settings.model_connection_edit"
                    : "settings.custom_model_add",
                )}
              </Dialog.Title>
              <Dialog.Description>
                {t(
                  editing
                    ? "settings.model_connection_edit_help"
                    : "settings.model_connection_dialog_help",
                )}
              </Dialog.Description>
              <form
                className="settings-model-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  void submit();
                }}
              >
                {!editing && (
                  <label className="settings-model-form-field">
                    <span>{t("settings.model_connection_provider")}</span>
                    <SelectionMenu
                      triggerClassName="settings-control"
                      value={draft.choice}
                      options={choiceOptions}
                      placeholder={t(
                        "settings.model_connection_choose_provider",
                      )}
                      ariaLabel={t("settings.model_connection_provider")}
                      disabled={busy || editing}
                      onValueChange={choose}
                    />
                  </label>
                )}
                {draft.choice && (
                  <>
                    {!provider && (
                      <label className="settings-model-form-field">
                        <span>{t("settings.api_key")}</span>
                        <input
                          className="settings-custom-provider-input focus-ring"
                          type="password"
                          autoComplete="off"
                          maxLength={8192}
                          value={draft.apiKey}
                          disabled={busy}
                          onChange={(event) =>
                            setDraft({ ...draft, apiKey: event.target.value })
                          }
                        />
                      </label>
                    )}
                    <label className="settings-model-form-field">
                      <span>{t("settings.custom_model_id")}</span>
                      {preset && !editing ? (
                        <SelectionMenu
                          triggerClassName="settings-control"
                          value={draft.modelId}
                          options={preset.modelIds.map((id) => ({
                            value: id,
                            label: id,
                          }))}
                          placeholder={t("account.choose_model")}
                          ariaLabel={t("settings.custom_model_id")}
                          disabled={busy}
                          onValueChange={(modelId) =>
                            setDraft({ ...draft, modelId })
                          }
                        />
                      ) : (
                        <input
                          className="settings-custom-provider-input settings-custom-provider-input-mono focus-ring"
                          maxLength={256}
                          autoComplete="off"
                          value={draft.modelId}
                          disabled={busy}
                          onChange={(event) =>
                            setDraft({ ...draft, modelId: event.target.value })
                          }
                        />
                      )}
                    </label>
                    {!preset && (
                      <details
                        open={draft.choice === "custom"}
                        className="settings-model-connection-details"
                      >
                        <summary>
                          {t("settings.model_connection_details")}
                        </summary>
                        {provider && (
                          <p>
                            {t("settings.model_connection_shared", {
                              count: provider.models.length,
                            })}
                          </p>
                        )}
                        <label className="settings-model-form-field">
                          <span>{t("settings.custom_provider_protocol")}</span>
                          <SelectionMenu
                            triggerClassName="settings-control"
                            value={draft.protocol}
                            options={(
                              Object.keys(providerRequestPaths) as Protocol[]
                            ).map((protocol) => ({
                              value: protocol,
                              label: t(
                                `settings.custom_provider_protocol.${protocol}`,
                              ),
                            }))}
                            placeholder={t("settings.custom_provider_protocol")}
                            ariaLabel={t("settings.custom_provider_protocol")}
                            disabled={busy || (provider != null && !editing)}
                            onValueChange={(protocol) =>
                              setDraft({
                                ...draft,
                                protocol: protocol as Protocol,
                              })
                            }
                          />
                        </label>
                        <label className="settings-model-form-field">
                          <span>{t("settings.custom_provider_endpoint")}</span>
                          <input
                            className="settings-custom-provider-input focus-ring"
                            type="url"
                            autoComplete="off"
                            value={draft.baseUrl}
                            maxLength={2048}
                            placeholder={examples[draft.protocol]}
                            disabled={busy || (provider != null && !editing)}
                            onChange={(event) =>
                              setDraft({
                                ...draft,
                                baseUrl: event.target.value,
                              })
                            }
                          />
                        </label>
                        <p className="settings-model-endpoint">
                          {t("settings.custom_provider_endpoint_preview", {
                            endpoint: customProviderEndpointFromBaseUrl(
                              draft.protocol,
                              draft.baseUrl,
                            ),
                          })}
                        </p>
                        {draft.baseUrl.trim() && (
                          <p>
                            {t("settings.builtin_provider_address_warning", {
                              host: (() => {
                                try {
                                  return new URL(draft.baseUrl).host;
                                } catch {
                                  return draft.baseUrl.trim();
                                }
                              })(),
                            })}
                          </p>
                        )}
                        {provider && editing && (
                          <Button
                            type="button"
                            variant="secondary"
                            size="sm"
                            disabled={busy || !draft.baseUrl.trim()}
                            onClick={() =>
                              void perform(() =>
                                actions.onUpdateCustomProvider({
                                  providerId: provider.id,
                                  expectedProviderRevision:
                                    provider.providerRevision,
                                  displayName: provider.displayName,
                                  protocol: draft.protocol,
                                  normalizedBaseUrl:
                                    customProviderEndpointFromBaseUrl(
                                      draft.protocol,
                                      draft.baseUrl,
                                    ),
                                }),
                              )
                            }
                          >
                            {t("settings.model_connection_save")}
                          </Button>
                        )}
                      </details>
                    )}
                    {provider && editing && (
                      <div className="settings-model-connection-details">
                        {preset && (
                          <p>
                            {t("settings.model_connection_shared", {
                              count: provider.models.length,
                            })}
                          </p>
                        )}
                        {preset &&
                          customProviderBaseUrl(provider) !==
                            preset.defaultBaseUrl && (
                            <p>
                              {t("settings.builtin_provider_address_warning", {
                                host: new URL(provider.normalizedBaseUrl).host,
                              })}
                            </p>
                          )}
                        <label className="settings-model-form-field">
                          <span>{t("settings.api_key")}</span>
                          <input
                            className="settings-custom-provider-input focus-ring"
                            type="password"
                            autoComplete="off"
                            value={draft.apiKey}
                            disabled={busy}
                            maxLength={8192}
                            onChange={(event) =>
                              setDraft({
                                ...draft,
                                apiKey: event.target.value,
                              })
                            }
                          />
                        </label>
                        <Button
                          type="button"
                          variant="secondary"
                          size="sm"
                          disabled={busy || !draft.apiKey}
                          onClick={() =>
                            void perform(() =>
                              actions.onReplaceCustomProviderCredential(
                                provider.id,
                                provider.providerRevision,
                                draft.apiKey,
                              ),
                            )
                          }
                        >
                          {t("settings.provider_save_api_key")}
                        </Button>
                      </div>
                    )}
                    {preset && (
                      <p className="text-xs text-(--ui-content-muted)">
                        <a
                          className="text-(--ui-action-primary) hover:underline"
                          href={preset.apiKeyUrl}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {t("settings.get_api_key")}
                        </a>{" "}
                        ·{" "}
                        <a
                          className="text-(--ui-action-primary) hover:underline"
                          href={preset.documentationUrl}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {t("settings.open_provider_docs")}
                        </a>
                      </p>
                    )}
                    {provider && provider.credentialStatus !== "ready" && (
                      <p role="status">
                        {t(
                          `settings.custom_provider_credential.${provider.credentialStatus}`,
                        )}
                      </p>
                    )}
                  </>
                )}
                {failed && <p role="alert">{t("execution.command_failed")}</p>}
                <div className="settings-model-form-actions">
                  <Button
                    type="button"
                    variant="ghost"
                    disabled={pending}
                    onClick={close}
                  >
                    {t("common.cancel")}
                  </Button>
                  <Button
                    type="submit"
                    disabled={
                      busy ||
                      !draft.choice ||
                      !draft.modelId.trim() ||
                      (editing &&
                        draft.modelId.trim() === draft.originalModelId) ||
                      (!provider && (!draft.apiKey || !draft.baseUrl.trim()))
                    }
                  >
                    {pending ? t("common.saving") : t("common.save")}
                  </Button>
                </div>
              </form>
            </Dialog.Popup>
          </Dialog.Portal>
        )}
      </Dialog.Root>
      <AlertDialog.Root
        open={removal !== null}
        onOpenChange={(open) => {
          if (!open && !pending) setRemoval(null);
        }}
      >
        <AlertDialog.Portal>
          <AlertDialog.Backdrop className="settings-model-dialog-backdrop" />
          <AlertDialog.Popup className="settings-model-dialog">
            <AlertDialog.Title>
              {t("settings.custom_model_remove_confirm")}
            </AlertDialog.Title>
            <AlertDialog.Description>
              {t("settings.custom_model_remove_description", {
                model:
                  removal?.source.models.find(
                    (model) => model.id === removal.modelId,
                  )?.displayName ||
                  removal?.modelId ||
                  "",
              })}
            </AlertDialog.Description>
            {failed && <p role="alert">{t("execution.command_failed")}</p>}
            <div className="delete-confirmation-actions">
              <Button
                autoFocus
                variant="secondary"
                disabled={pending}
                onClick={() => setRemoval(null)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                variant="danger"
                disabled={busy}
                onClick={() => void remove()}
              >
                {t("common.remove")}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </section>
  );
}
