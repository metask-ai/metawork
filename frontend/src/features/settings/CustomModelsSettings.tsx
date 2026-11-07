import { useEffect, useRef, useState } from "react";
import type {
  BuiltinProviderId,
  CustomProviderView,
  ModelsView,
  Protocol,
} from "../../bridge/contracts.ts";
import { Checkbox } from "../../components/ui/checkbox.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Badge } from "../../components/ui/badge.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { BrandIcon } from "../../components/ui/BrandIcon.tsx";
import { useI18n } from "../../i18n/context.ts";

import {
  builtinProviderEndpoint,
  inspectModelEndpoint,
  protocolFromEndpoint,
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
  openai_responses: "https://api.openai.com/v1/responses",
  openai_chat_completions: "https://api.openai.com/v1/chat/completions",
  anthropic_messages: "https://api.anthropic.com/v1/messages",
  gemini_native: "https://generativelanguage.googleapis.com",
};
export type ModelEditPart = "address" | "api_key" | "model_id";
export type CustomModelEditInput = {
  providerId: string;
  expectedProviderRevision: string;
  expectedCatalogGeneration: string;
  modelId: string;
  nextModelId: string;
  protocol: Protocol;
  endpoint: string;
  apiKey: string;
};
export type CustomModelEditResult = {
  accepted: boolean;
  applied: ModelEditPart[];
  source: CustomProviderView | null;
  modelId: string;
  reviewRequired: boolean;
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
  onSaveCustomModel: (
    input: CustomModelEditInput,
  ) => Promise<CustomModelEditResult>;
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
  ) => Promise<boolean>;
};
type Draft = {
  choice: string;
  modelId: string;
  originalModelId: string | null;
  providerId: string | null;
  revision: string | null;
  catalogGeneration: string | null;
  protocol: Protocol | null;
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
  protocol: null,
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
  const [savedParts, setSavedParts] = useState<ModelEditPart[]>([]);
  const [addressTouched, setAddressTouched] = useState(false);
  const [testFailure, setTestFailure] = useState<{
    sourceId: string;
    modelId: string;
    name: string;
  } | null>(null);
  const [reviewNotice, setReviewNotice] = useState(false);
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
  const endpoint = inspectModelEndpoint(draft?.baseUrl ?? "");
  const detectedProtocol = endpoint.protocol;
  const addressInvalid = !preset && endpoint.issue !== null;
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
    setSavedParts([]);
    setAddressTouched(false);
    setReviewNotice(false);
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
            baseUrl: source.normalizedBaseUrl,
            modelId: modelId ?? "",
            originalModelId: modelId,
          }
        : emptyDraft(),
    );
  }
  useEffect(() => {
    if (!draft?.providerId || pending) return;
    const current = models.customProviders.find(
      (item) => item.id === draft.providerId,
    );
    if (
      !current ||
      current.providerRevision !== draft.revision ||
      current.catalogGeneration !== draft.catalogGeneration
    ) {
      close();
      setReviewNotice(true);
    }
  }, [
    models.customProviders,
    draft?.providerId,
    draft?.revision,
    draft?.catalogGeneration,
    pending,
  ]);
  useEffect(() => {
    if (!removal || pending) return;
    const current = models.customProviders.find(
      (item) => item.id === removal.source.id,
    );
    if (
      !current ||
      !current.models.some((model) => model.id === removal.modelId)
    )
      setRemoval(null);
    else if (
      current.providerRevision !== removal.source.providerRevision ||
      current.catalogGeneration !== removal.source.catalogGeneration
    ) {
      setRemoval({ ...removal, source: current });
    }
  }, [models.customProviders, removal, pending]);
  function choose(value: string) {
    const recipe = models.builtinProviderPresets.find(
      (item) => value === `preset:${item.id}`,
    );
    setFailed(false);
    setAddressTouched(false);
    setDraft({
      ...emptyDraft(),
      choice: value,
      protocol: recipe?.protocol ?? null,
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
    if (!draft || !draft.modelId.trim() || !draft.protocol || addressInvalid)
      return;
    const protocol = draft.protocol;
    const modelId = draft.modelId.trim();
    if (
      editing &&
      provider &&
      modelId === draft.originalModelId &&
      !draft.apiKey &&
      draft.protocol === provider.protocol &&
      draft.baseUrl.trim() === provider.normalizedBaseUrl
    )
      return;
    if (editing) {
      if (!provider) return;
      const version = dialogVersion.current;
      setPending(true);
      setFailed(false);
      setSavedParts([]);
      try {
        const outcome = await actions.onSaveCustomModel({
          providerId: provider.id,
          expectedProviderRevision: draft.revision!,
          expectedCatalogGeneration: draft.catalogGeneration!,
          modelId: draft.originalModelId!,
          nextModelId: modelId,
          protocol,
          endpoint: draft.baseUrl.trim(),
          apiKey: draft.apiKey,
        });
        if (version !== dialogVersion.current) return;
        if (outcome.accepted) close();
        else if (outcome.reviewRequired || !outcome.source) {
          close();
          setReviewNotice(true);
        } else {
          const source = outcome.source;
          setDraft((current) =>
            current
              ? {
                  ...current,
                  apiKey: "",
                  revision: source.providerRevision,
                  catalogGeneration: source.catalogGeneration,
                  originalModelId: outcome.modelId,
                }
              : null,
          );
          setFailed(true);
          setSavedParts(outcome.applied);
        }
      } catch {
        if (version === dialogVersion.current) {
          close();
          setReviewNotice(true);
        }
      } finally {
        setPending(false);
      }
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
          protocol,
          normalizedBaseUrl: draft.baseUrl.trim(),
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
      leading: <BrandIcon brand={recipe.id} />,
    })),
    {
      value: "custom",
      label: t("settings.model_connection_custom"),
      leading: <BrandIcon />,
    },
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
      {reviewNotice && (
        <p role="alert" className="text-sm text-(--ui-content-muted)">
          {t("settings.model_edit_review")}
        </p>
      )}
      {testFailure &&
        rows.some(
          ({ source, model }) =>
            source.id === testFailure.sourceId &&
            model.id === testFailure.modelId,
        ) && (
          <p role="alert">
            {t("settings.custom_model_test_start_failed", {
              model: testFailure.name,
            })}
          </p>
        )}
      <div className="settings-model-list">
        {rows.map(({ source, model }) => (
          <div
            className="settings-model-row"
            key={JSON.stringify([source.id, model.id])}
          >
            <div className="settings-model-identity">
              <strong>
                <BrandIcon brand={source.builtinProviderId ?? "custom"} />
                <span>{model.displayName || model.id}</span>
              </strong>
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
                onClick={async () => {
                  setTestFailure(null);
                  try {
                    const accepted = await actions.onTestCustomModel(
                      source.id,
                      source.providerRevision,
                      model.id,
                      source.sourceGeneration,
                      source.catalogGeneration,
                    );
                    if (accepted === false)
                      setTestFailure({
                        sourceId: source.id,
                        modelId: model.id,
                        name: model.displayName || model.id,
                      });
                  } catch {
                    setTestFailure({
                      sourceId: source.id,
                      modelId: model.id,
                      name: model.displayName || model.id,
                    });
                  }
                }}
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
                  returnFocus.current =
                    document.activeElement instanceof HTMLElement
                      ? document.activeElement
                      : addButton.current;
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
                      leading={
                        draft.choice ? (
                          <BrandIcon brand={preset?.id ?? "custom"} />
                        ) : undefined
                      }
                      disabled={busy}
                      onValueChange={choose}
                    />
                  </label>
                )}
                {draft.choice && (
                  <>
                    {!preset && (
                      <>
                        {provider && editing && provider.models.length > 1 && (
                          <p className="text-xs text-(--ui-content-muted)">
                            {t("settings.model_connection_shared", {
                              count: provider.models.length,
                            })}
                          </p>
                        )}
                        <label className="settings-model-form-field">
                          <span>
                            {t(
                              draft.protocol === "gemini_native"
                                ? "settings.custom_model_base_url"
                                : "settings.custom_provider_endpoint",
                            )}
                          </span>
                          <Input
                            className="settings-custom-provider-input"
                            type="url"
                            autoComplete="off"
                            value={draft.baseUrl}
                            aria-invalid={
                              (addressTouched && addressInvalid) || undefined
                            }
                            onBlur={() => setAddressTouched(true)}
                            aria-describedby="model-endpoint-help"
                            maxLength={2048}
                            placeholder={
                              examples[
                                draft.protocol ?? "openai_chat_completions"
                              ]
                            }
                            disabled={busy || (provider != null && !editing)}
                            onChange={(event) =>
                              setDraft({
                                ...draft,
                                baseUrl: event.target.value,
                                protocol: protocolFromEndpoint(
                                  event.target.value,
                                ),
                              })
                            }
                          />
                        </label>
                        <div id="model-endpoint-help" className="grid gap-1">
                          {detectedProtocol ? (
                            <p
                              role="status"
                              className="text-xs text-(--ui-content-muted)"
                            >
                              {t("settings.custom_model_protocol_detected", {
                                protocol: t(
                                  `settings.custom_provider_protocol.${detectedProtocol}`,
                                ),
                              })}
                            </p>
                          ) : endpoint.root ? (
                            <>
                              {draft.protocol !== "gemini_native" && (
                                <p className="text-xs text-(--ui-content-muted)">
                                  {t("settings.custom_model_root_help")}
                                </p>
                              )}
                              <label className="flex min-h-11 items-center gap-2 text-sm">
                                <Checkbox.Root
                                  checked={draft.protocol === "gemini_native"}
                                  disabled={busy}
                                  onCheckedChange={(checked) =>
                                    setDraft({
                                      ...draft,
                                      protocol: checked
                                        ? "gemini_native"
                                        : null,
                                    })
                                  }
                                >
                                  <Checkbox.Indicator aria-hidden="true">
                                    ✓
                                  </Checkbox.Indicator>
                                </Checkbox.Root>
                                {t("settings.custom_model_gemini_confirm")}
                              </label>
                            </>
                          ) : addressTouched && endpoint.issue ? (
                            <p
                              role="alert"
                              className="text-sm text-(--ui-content-danger)"
                            >
                              {t(
                                `settings.custom_model_address_error.${endpoint.issue}`,
                              )}
                            </p>
                          ) : (
                            <p className="text-xs text-(--ui-content-muted)">
                              {t("settings.custom_model_protocol_automatic")}
                            </p>
                          )}
                          {draft.protocol === "gemini_native" && (
                            <p className="text-xs text-(--ui-content-muted)">
                              {t("settings.custom_model_gemini_address_help")}
                            </p>
                          )}
                          {draft.baseUrl.trim() && !endpoint.issue && (
                            <p className="text-xs text-(--ui-content-muted)">
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
                        </div>
                      </>
                    )}
                    {!provider && (
                      <label className="settings-model-form-field">
                        <span>{t("settings.api_key")}</span>
                        <Input
                          className="settings-custom-provider-input"
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
                    {provider && editing && (
                      <div className="settings-model-connection-details">
                        {preset && provider.models.length > 1 && (
                          <p>
                            {t("settings.model_connection_shared", {
                              count: provider.models.length,
                            })}
                          </p>
                        )}
                        {preset &&
                          provider.normalizedBaseUrl !==
                            builtinProviderEndpoint(preset) && (
                            <p>
                              {t("settings.builtin_provider_address_warning", {
                                host: new URL(provider.normalizedBaseUrl).host,
                              })}
                            </p>
                          )}
                        <label className="settings-model-form-field">
                          <span>{t("settings.api_key")}</span>
                          <Input
                            className="settings-custom-provider-input"
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
                      </div>
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
                        <Input
                          className="settings-custom-provider-input settings-custom-provider-input-mono"
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
                {failed && (
                  <p role="alert">
                    {t(
                      savedParts.length > 0
                        ? "settings.model_edit_partial"
                        : "execution.command_failed",
                      {
                        fields: savedParts
                          .map((part) =>
                            t(
                              part === "address"
                                ? "settings.custom_provider_endpoint"
                                : part === "api_key"
                                  ? "settings.api_key"
                                  : "settings.custom_model_id",
                            ),
                          )
                          .join("、"),
                      },
                    )}
                  </p>
                )}
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
                      !draft.protocol ||
                      addressInvalid ||
                      (editing &&
                        draft.modelId.trim() === draft.originalModelId &&
                        !draft.apiKey &&
                        draft.protocol === provider?.protocol &&
                        draft.baseUrl.trim() === provider?.normalizedBaseUrl) ||
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
          <AlertDialog.Popup
            className="settings-model-dialog"
            finalFocus={() =>
              returnFocus.current?.isConnected
                ? returnFocus.current
                : addButton.current
            }
          >
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
            {failed && (
              <p role="alert">{t("settings.custom_model_remove_failed")}</p>
            )}
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
