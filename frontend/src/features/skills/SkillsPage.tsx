import { useEffect, useMemo, useRef, useState } from "react";

import type {
  SkillDetailResult,
  SkillExportResult,
  SkillEnablementResult,
  SkillImportPreview,
  SkillImportTarget,
  SkillImportEffect,
  SkillMutationReason,
  SkillCatalogView,
  SkillManagementView,
  SkillMutationResult,
} from "../../bridge/contracts.ts";
import { Markdown } from "../../components/ai/Markdown.tsx";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { HeaderSearch } from "../../components/ui/HeaderSearch.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { Input } from "../../components/ui/input.tsx";
import { Switch } from "../../components/ui/switch.tsx";
import { useI18n } from "../../i18n/context.ts";

type Asset = SkillManagementView["assets"][number];
type ImportKind = "package" | "directory";
type PersonalImportTarget = Extract<
  SkillImportTarget,
  { kind: "personal" | "reimport" }
>;
type PreparedImport = Extract<SkillImportPreview, { status: "prepared" }>;

function ImportChoices({ onChoose }: { onChoose: (kind: ImportKind) => void }) {
  const { t } = useI18n();
  return (
    <>
      <Menu.Item onClick={() => onChoose("package")}>
        <Icon name="package" />
        {t("skills.choose_package")}
      </Menu.Item>
      <Menu.Item onClick={() => onChoose("directory")}>
        <Icon name="folder-up" />
        {t("skills.choose_folder")}
      </Menu.Item>
    </>
  );
}

function ImportMenu({
  label,
  icon = "upload",
  disabled,
  onChoose,
}: {
  label: string;
  icon?: "plus" | "upload";
  disabled: boolean;
  onChoose: (kind: ImportKind, trigger: HTMLElement | null) => void;
}) {
  const { t } = useI18n();
  const trigger = useRef<HTMLButtonElement>(null);
  return (
    <Menu.Root>
      <Menu.Trigger
        ref={trigger}
        disabled={disabled}
        render={
          <Button className="skill-import-button" variant="primary" size="sm" />
        }
      >
        <Icon name={icon} />
        {label}
        <Icon name="chevron" />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner align="end">
          <Menu.Popup>
            <ImportChoices
              onChoose={(kind) => onChoose(kind, trigger.current)}
            />
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

export function filterSkills(assets: Asset[], query: string): Asset[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return assets;
  return assets.filter((asset) =>
    [
      asset.invocationName,
      asset.displayName,
      asset.description,
      ...asset.argumentNames,
    ].some((value) => value.toLocaleLowerCase().includes(needle)),
  );
}

function skillRowIdentity(asset: Asset): string {
  return `${asset.installId ?? ""}:${asset.skillId ?? ""}:${asset.invocationName}`;
}

function skillAttention(asset: Asset) {
  if (asset.managementState === "recovery_required") return "recovery_required";
  if (asset.managementState === "pending_verification") return "pending";
  return asset.issueCodes.length > 0 ? "issue" : null;
}

function skillBody(definition: string, title: string) {
  const leadingBlankLines = /^(?:[ \t]*\r?\n)+/;
  const body = definition.replace(leadingBlankLines, "");
  const heading = /^#[ \t]+([^\r\n]+)(?:\r?\n|$)/.exec(body);
  return heading &&
    heading[1].trim().toLowerCase() === title.trim().toLowerCase()
    ? body.slice(heading[0].length).replace(leadingBlankLines, "")
    : body;
}

function SkillContent({
  asset,
  onDetail,
}: {
  asset: Asset;
  onDetail: (installId: string) => Promise<SkillDetailResult>;
}) {
  const { t } = useI18n();
  const [detail, setDetail] = useState<SkillDetailResult | "error" | null>(
    null,
  );
  const requested = useRef(false);
  const installId =
    asset.managementState === "recovery_required" ? null : asset.installId;

  useEffect(() => {
    if (!installId || requested.current) return;
    requested.current = true;
    void onDetail(installId).then(setDetail, () => setDetail("error"));
  }, [installId, onDetail]);

  if (!installId) return null;

  if (detail === null || detail === "error" || !detail.available) {
    return (
      <p
        className="skill-detail-content skill-detail-content-status"
        role="status"
      >
        {t(
          detail === null
            ? "skills.detail.loading"
            : "skills.detail.unavailable",
        )}
      </p>
    );
  }

  const body = skillBody(
    detail.definition,
    asset.displayName || asset.invocationName,
  );
  return body.trim() ? (
    <Markdown className="skill-detail-content" interactive={false}>
      {body}
    </Markdown>
  ) : null;
}

function SkillRow({
  asset,
  onOpen,
  onSetState,
  enablementBusy,
}: {
  asset: Asset;
  onOpen: (asset: Asset, trigger: HTMLElement) => void;
  onSetState: (asset: Asset, state: "enabled" | "disabled") => void;
  enablementBusy: boolean;
}) {
  const { t } = useI18n();
  const attention = skillAttention(asset);
  return (
    <li className="skill-row" data-attention={attention !== null}>
      <button
        className="skill-row-open focus-ring"
        onClick={(event) => onOpen(asset, event.currentTarget)}
      >
        <span className="skill-row-icon" aria-hidden="true">
          <Icon name="skill-file" />
        </span>
        <span className="skill-row-copy">
          <span className="skill-row-title">
            <strong>{asset.displayName || asset.invocationName}</strong>
            {asset.sourceKind === "builtin" && (
              <span className="skill-row-builtin">{t("skills.builtin")}</span>
            )}
          </span>
          <span className="skill-row-description">
            {asset.description || t("skills.no_description")}
          </span>
          {attention && (
            <span className="skill-row-attention">
              {t(`skills.status.${attention}`)}
            </span>
          )}
        </span>
      </button>
      {asset.enabled !== null && (
        <div className="skill-row-enablement">
          <span>
            {t(
              asset.enabled
                ? "skills.enablement.enabled"
                : "skills.enablement.disabled",
            )}
          </span>
          <Switch.Root
            className="h-4 w-7 data-checked:bg-(--metask-state-complete)"
            checked={asset.enabled}
            disabled={!asset.canSetEnabled || enablementBusy}
            aria-label={t("skills.enablement.label", {
              skill: asset.displayName || asset.invocationName,
            })}
            onCheckedChange={(checked) =>
              onSetState(asset, checked ? "enabled" : "disabled")
            }
          >
            <Switch.Thumb className="size-3 data-checked:translate-x-3" />
          </Switch.Root>
        </div>
      )}
    </li>
  );
}

export function SkillsPage({
  management,
  personalCatalog: catalog,
  query,
  refreshRequest,
  disabled,
  onQuery,
  onRefresh,
  onSetEnabled,
  onChooseImport,
  onDiscardImport,
  onInstall,
  onReimport,
  onUninstall,
  onRetry,
  onExport,
  onDetail,
}: {
  management: SkillManagementView;
  personalCatalog: SkillCatalogView;
  query: string;
  refreshRequest: { busy: boolean; error: string | null };
  disabled: boolean;
  onQuery: (query: string) => void;
  onRefresh: () => void;
  onSetEnabled: (
    skillPolicyKey: string,
    state: "enabled" | "disabled",
    expectedCatalogRevision: string,
    expectedSelectionRevision: string,
  ) => Promise<SkillEnablementResult>;
  onChooseImport: (
    kind: ImportKind,
    target: PersonalImportTarget,
  ) => Promise<SkillImportPreview>;
  onDiscardImport: (
    previewId: string,
    revision: string,
  ) => Promise<SkillImportPreview>;
  onInstall: (
    previewId: string,
    revision: string,
    confirmation: SkillImportEffect,
  ) => Promise<SkillMutationResult>;
  onReimport: (
    previewId: string,
    revision: string,
    confirmation: SkillImportEffect,
  ) => Promise<SkillMutationResult>;
  onUninstall: (installId: string) => Promise<SkillMutationResult>;
  onRetry: (installId: string) => Promise<SkillMutationResult>;
  onExport: (installId: string) => Promise<SkillExportResult>;
  onDetail: (installId: string) => Promise<SkillDetailResult>;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const dialogHeading = useRef<HTMLHeadingElement>(null);
  const dialog = useRef<HTMLDivElement>(null);
  const dialogTrigger = useRef<HTMLElement | null>(null);
  const detailMenuTrigger = useRef<HTMLButtonElement>(null);
  const uninstallTrigger = useRef<HTMLButtonElement>(null);
  const cancelUninstall = useRef<HTMLButtonElement>(null);
  const [selected, setSelected] = useState<Asset | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [preview, setPreview] = useState<PreparedImport | null>(null);
  const [reimportTarget, setReimportTarget] = useState<Asset | null>(null);
  const importAudience = useRef(0);
  const previewRef = useRef<PreparedImport | null>(null);
  previewRef.current = preview;
  const discardRef = useRef(onDiscardImport);
  discardRef.current = onDiscardImport;
  const [busy, setBusy] = useState(false);
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [enablementBusy, setEnablementBusy] = useState(false);
  const [enablementFailure, setEnablementFailure] = useState<{
    identity: string;
    name: string;
  } | null>(null);

  const personalAssets = useMemo(
    () => management.assets.filter((asset) => asset.scope.kind === "personal"),
    [management.assets],
  );
  const visibleAssets = useMemo(
    () => filterSkills(personalAssets, query),
    [personalAssets, query],
  );
  const attention = visibleAssets.filter(
    (asset) =>
      asset.managementState === "pending_verification" ||
      asset.managementState === "recovery_required",
  );
  const regular = visibleAssets.filter((asset) => !attention.includes(asset));
  const dialogOpen = selected !== null || importOpen;
  const selectedAttention = selected && skillAttention(selected);
  const detailEnablementFailed =
    selected && enablementFailure?.identity === skillRowIdentity(selected);
  const enablementError =
    enablementFailure &&
    t("skills.error.enablement", { skill: enablementFailure.name });
  const shadowsBuiltin =
    preview?.effect === "create" &&
    personalAssets.some(
      (asset) =>
        asset.sourceKind === "builtin" &&
        asset.invocationName === preview.invocationName,
    );
  const showDetailMenu =
    selected?.installId && (selected.canExport || selected.canReimport);
  const showDetailActions =
    selected &&
    (selected.canSetEnabled ||
      (selected.installId && (selected.canRetry || selected.canUninstall)));
  const refreshing = refreshRequest.busy || catalog.availability === "loading";

  async function setEnablementState(
    asset: Asset,
    state: "enabled" | "disabled",
  ) {
    if (
      enablementBusy ||
      !asset.canSetEnabled ||
      !asset.skillPolicyKey ||
      !asset.selectionRevision ||
      !catalog.revision
    )
      return;
    const failure = {
      identity: skillRowIdentity(asset),
      name: asset.displayName || asset.invocationName,
    };
    setEnablementBusy(true);
    setEnablementFailure((current) =>
      current?.identity === failure.identity ? null : current,
    );
    try {
      const result = await onSetEnabled(
        asset.skillPolicyKey,
        state,
        catalog.revision,
        asset.selectionRevision,
      );
      if (!result.applied) setEnablementFailure(failure);
    } catch {
      setEnablementFailure(failure);
    } finally {
      setEnablementBusy(false);
    }
  }

  useEffect(() => title.current?.focus(), []);
  useEffect(() => {
    importAudience.current += 1;
    discardPreview();
    setImportOpen(false);
    setBusy(false);
    setConfirmUninstall(false);
  }, [disabled]);
  useEffect(
    () => () => {
      importAudience.current += 1;
      const current = previewRef.current;
      if (current)
        void discardRef
          .current(current.previewId, current.preparationRevision)
          .catch(() => {});
    },
    [],
  );

  useEffect(() => {
    if (!selected) return;
    const selectedIdentity = skillRowIdentity(selected);
    const current = personalAssets.find(
      (asset) => skillRowIdentity(asset) === selectedIdentity,
    );
    if (current) setSelected(current);
    else closeDialog();
    // closeDialog deliberately follows the committed personal inventory.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [personalAssets]);

  function rememberTrigger(trigger?: HTMLElement) {
    dialogTrigger.current =
      trigger ??
      (document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null);
  }

  function discardPreview() {
    const current = previewRef.current;
    previewRef.current = null;
    setPreview(null);
    if (current)
      void discardRef
        .current(current.previewId, current.preparationRevision)
        .catch(() => {});
  }

  function closeDialog() {
    importAudience.current += 1;
    discardPreview();
    setSelected(null);
    setImportOpen(false);
    setPreview(null);
    setBusy(false);
    setReimportTarget(null);

    setConfirmUninstall(false);
    setNotice(null);
    setError(null);
  }

  function openDetail(asset: Asset, trigger: HTMLElement) {
    rememberTrigger(trigger);
    setImportOpen(false);
    setSelected(asset);
    setError(null);
  }

  function importError(reason: SkillMutationReason) {
    return t(`skills.import_error.${reason}`);
  }

  async function beginImport(
    kind: ImportKind,
    trigger: HTMLElement | null,
    target?: Asset,
  ) {
    if (busy || disabled) return;
    if (!trigger || !dialog.current?.contains(trigger))
      rememberTrigger(trigger ?? undefined);
    discardPreview();
    const audience = ++importAudience.current;
    const intent: PersonalImportTarget = target?.installId
      ? { kind: "reimport", installId: target.installId }
      : { kind: "personal" };
    setSelected(null);
    setImportOpen(false);
    setReimportTarget(target ?? null);
    setError(null);
    setNotice(null);
    setBusy(true);
    try {
      const chosen = await onChooseImport(kind, intent);
      if (audience !== importAudience.current) {
        if (chosen.status === "prepared")
          void onDiscardImport(
            chosen.previewId,
            chosen.preparationRevision,
          ).catch(() => {});
        return;
      }
      if (chosen.status === "cancelled") return;
      setImportOpen(true);
      if (chosen.status === "rejected") {
        setError(importError(chosen.reason));
        return;
      }
      if (chosen.scope.kind !== "personal") {
        void onDiscardImport(
          chosen.previewId,
          chosen.preparationRevision,
        ).catch(() => {});
        setError(importError("invalid_preview"));
        return;
      }
      setPreview(chosen);
    } catch {
      if (audience === importAudience.current) {
        setImportOpen(true);
        setError(t("skills.error.preview"));
      }
    } finally {
      if (audience === importAudience.current) setBusy(false);
    }
  }

  async function commitImport() {
    if (!preview || busy || disabled) return;
    const audience = ++importAudience.current;
    setBusy(true);
    setError(null);
    try {
      const result = await (reimportTarget ? onReimport : onInstall)(
        preview.previewId,
        preview.preparationRevision,
        preview.effect,
      );
      if (audience !== importAudience.current) return;
      if (!result.accepted) {
        setError(importError(result.reason));
        if (
          !["busy", "capacity_reached", "catalog_loading"].includes(
            result.reason,
          )
        )
          discardPreview();
        return;
      }
      // Committed work continues in Host; closing never cancels a transaction.
      previewRef.current = null;
      setPreview(null);
      closeDialog();
    } catch {
      if (audience === importAudience.current) {
        previewRef.current = null;
        setPreview(null);
        setError(importError("outcome_unknown"));
      }
    } finally {
      if (audience === importAudience.current) setBusy(false);
    }
  }

  async function runMutation(
    action: () => Promise<SkillMutationResult>,
    close = false,
  ) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const result = await action();
      if (!result.accepted) {
        setError(t("skills.error.mutation"));
        return;
      }
      if (close) closeDialog();
    } catch {
      setError(t("skills.error.mutation"));
    } finally {
      setBusy(false);
    }
  }

  async function runExport() {
    if (!selected?.installId || busy) return;
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const result = await onExport(selected.installId);
      if (!result.exported) {
        setError(
          result.reason === "too_large"
            ? t("skills.error.export_too_large")
            : t("skills.error.export"),
        );
        return;
      }
      setNotice(t("skills.exported", { file: result.fileName }));
    } catch {
      setError(t("skills.error.export"));
    } finally {
      setBusy(false);
    }
  }

  function renderGroup(label: string, assets: Asset[]) {
    if (assets.length === 0) return null;
    return (
      <section className="skill-group" aria-label={label}>
        <header>
          <h2>{label}</h2>
          <span>{assets.length}</span>
        </header>
        <ul className="skill-list" aria-label={label}>
          {assets.map((asset) => (
            <SkillRow
              key={skillRowIdentity(asset)}
              asset={asset}
              onOpen={openDetail}
              onSetState={(item, state) => void setEnablementState(item, state)}
              enablementBusy={enablementBusy}
            />
          ))}
        </ul>
      </section>
    );
  }

  const operation = management.importOperation;
  const currentOperation =
    preview &&
    operation?.id === preview.operationId &&
    operation.preparationRevision === preview.preparationRevision
      ? operation
      : null;
  const importBlocker = currentOperation
    ? (currentOperation.blocker ??
      (currentOperation.canConfirm ? null : "invalid_preview"))
    : (preview?.blocker ?? null);
  const visibleOperation =
    operation &&
    operation.phase !== "prepared" &&
    operation.phase !== "cancelled" &&
    operation.scope.kind === "personal"
      ? operation
      : null;

  const personalRootError = management.personalSourceDiscovery?.find(
    (check) => check.state === "error",
  )?.reason;
  const unavailable = management.availability !== "ready";
  const empty = personalAssets.length === 0;
  const noResults = !empty && visibleAssets.length === 0;
  const refreshLabel = t(refreshing ? "skills.refreshing" : "skills.refresh");

  return (
    <section className="skills-page" aria-labelledby="skills-title">
      <div className="skills-page-inner">
        <header className="skills-header">
          <div>
            <h1 id="skills-title" ref={title} tabIndex={-1}>
              {t("skills.title")}
            </h1>
            <p>{t("skills.subtitle")}</p>
          </div>
          <div className="skill-header-actions">
            <Button
              variant="ghost"
              size="icon"
              className="skill-refresh-button aria-busy:[&_svg]:animate-spin motion-reduce:[&_svg]:animate-none"
              aria-label={refreshLabel}
              aria-busy={refreshing}
              title={refreshLabel}
              disabled={disabled || refreshing}
              onClick={onRefresh}
            >
              <Icon name="refresh" />
            </Button>
            {!unavailable && (
              <HeaderSearch
                label={t("skills.search_label")}
                clearLabel={t("skills.clear_search")}
                value={query}
                onChange={onQuery}
              />
            )}
            <ImportMenu
              label={t("skills.import.action")}
              icon="plus"
              disabled={disabled || unavailable || busy}
              onChoose={(kind, trigger) => void beginImport(kind, trigger)}
            />
          </div>
        </header>

        {visibleOperation && (
          <p className="skill-dialog-notice" role="status">
            {t(`skills.operation.${visibleOperation.phase}`, {
              skill: visibleOperation.invocationName,
            })}
            {visibleOperation.reason &&
              ` ${importError(visibleOperation.reason)}`}
          </p>
        )}

        {refreshRequest.error && (
          <p className="skill-enablement-error" role="alert">
            {refreshRequest.error}
          </p>
        )}
        {catalog.issues.length ? (
          <section
            className="skill-group skill-catalog-issues"
            aria-label={t("skills.catalog_issues")}
          >
            <header>
              <h2>{t("skills.catalog_issues")}</h2>
              <span>{catalog.issues.length}</span>
            </header>
            <ul>
              {catalog.issues.map((issue, index) => (
                <li
                  key={`${issue.code}:${issue.invocationName ?? ""}:${index}`}
                >
                  {issue.invocationName && (
                    <code>{issue.invocationName} · </code>
                  )}
                  {t(`skills.issue.${issue.code}`)}
                </li>
              ))}
            </ul>
            <p>{t("skills.catalog_issues_help")}</p>
          </section>
        ) : null}
        {(personalRootError ||
          !["ready", "degraded", "loading"].includes(catalog.availability)) && (
          <p className="skill-enablement-error" role="status">
            {personalRootError
              ? t("skills.personal_directory_error", {
                  reason: t(`skills.directory_error.${personalRootError}`),
                })
              : t("skills.catalog_unavailable")}
          </p>
        )}
        {enablementError && !detailEnablementFailed && (
          <p className="skill-enablement-error" role="alert">
            {enablementError}
          </p>
        )}

        {unavailable ? (
          <div className="skill-empty-state">
            <span>
              <Icon name="warning" />
            </span>
            <h2>{t("skills.unavailable_title")}</h2>
            <p role="status">
              {t(
                management.availability === "write_failed" ||
                  management.availability === "outcome_unknown"
                  ? "skills.restart_recovery_body"
                  : "skills.unavailable_body",
              )}
            </p>
          </div>
        ) : empty && catalog.availability === "loading" ? (
          <div
            className="skill-empty-state skill-empty-state-compact"
            role="status"
          >
            <p>{t("skills.refreshing")}</p>
          </div>
        ) : empty ? (
          <div className="skill-empty-state">
            <span>
              <Icon name="skill-file" />
            </span>
            <h2>
              {t(
                catalog.issues.length
                  ? "skills.no_available_title"
                  : "skills.empty_title",
              )}
            </h2>
            <p>
              {t(
                catalog.issues.length
                  ? "skills.catalog_issues_help"
                  : "skills.empty_body",
              )}
            </p>
            <ImportMenu
              label={t("skills.import_first")}
              disabled={disabled || busy}
              onChoose={(kind, trigger) => void beginImport(kind, trigger)}
            />
          </div>
        ) : noResults ? (
          <div className="skill-empty-state">
            <span>
              <Icon name="search" />
            </span>
            <h2>{t("skills.no_results_title")}</h2>
            <p>{t("skills.no_results_body", { query: query.trim() })}</p>
          </div>
        ) : (
          <div className="skill-groups">
            {renderGroup(t("skills.section.attention"), attention)}
            {renderGroup(t("skills.section.skills"), regular)}
          </div>
        )}
      </div>

      <Dialog.Root
        open={dialogOpen}
        onOpenChange={(open) => {
          if (!open && !busy) closeDialog();
        }}
      >
        <Dialog.Portal>
          <Dialog.Backdrop />
          <Dialog.Popup
            ref={dialog}
            className="skill-dialog w-[min(640px,calc(100vw-32px))] gap-0 overflow-hidden p-0"
            initialFocus={dialogHeading}
            finalFocus={() =>
              dialogTrigger.current?.isConnected
                ? dialogTrigger.current
                : title.current
            }
          >
            <header>
              <div>
                <Dialog.Title ref={dialogHeading} tabIndex={-1}>
                  {importOpen
                    ? reimportTarget
                      ? t("skills.reimport")
                      : t("skills.import")
                    : selected?.displayName || selected?.invocationName}
                </Dialog.Title>
              </div>
              <div className="skill-dialog-header-actions">
                {showDetailMenu && selected && (
                  <Menu.Root>
                    <Menu.Trigger
                      ref={detailMenuTrigger}
                      className="icon-button"
                      aria-label={t("skills.more_actions")}
                      disabled={busy || disabled}
                    >
                      <Icon name="more" />
                    </Menu.Trigger>
                    <Menu.Portal>
                      <Menu.Positioner align="end">
                        <Menu.Popup>
                          {selected.canExport && (
                            <Menu.Item onClick={() => void runExport()}>
                              <Icon name="download" />
                              {t("skills.export")}
                            </Menu.Item>
                          )}
                          {selected.canReimport && (
                            <Menu.SubmenuRoot>
                              <Menu.SubmenuTrigger openOnHover={false}>
                                <Icon name="upload" />
                                <span className="flex-1">
                                  {t("skills.reimport")}
                                </span>
                                <Icon name="chevron-right" />
                              </Menu.SubmenuTrigger>
                              <Menu.Portal>
                                <Menu.Positioner side="right" align="start">
                                  <Menu.Popup aria-label={t("skills.reimport")}>
                                    <ImportChoices
                                      onChoose={(kind) =>
                                        void beginImport(
                                          kind,
                                          detailMenuTrigger.current,
                                          selected,
                                        )
                                      }
                                    />
                                  </Menu.Popup>
                                </Menu.Positioner>
                              </Menu.Portal>
                            </Menu.SubmenuRoot>
                          )}
                        </Menu.Popup>
                      </Menu.Positioner>
                    </Menu.Portal>
                  </Menu.Root>
                )}
                <button
                  type="button"
                  className="icon-button focus-ring"
                  aria-label={t("common.close")}
                  disabled={busy}
                  onClick={() => closeDialog()}
                >
                  <Icon name="close" />
                </button>
              </div>
            </header>

            <div className="skill-dialog-scroll" tabIndex={0}>
              {importOpen ? (
                <>
                  {!preview ? (
                    <ImportMenu
                      label={t("skills.choose_again")}
                      disabled={disabled || busy}
                      onChoose={(kind, trigger) =>
                        void beginImport(
                          kind,
                          trigger,
                          reimportTarget ?? undefined,
                        )
                      }
                    />
                  ) : (
                    <>
                      <div className="skill-import-preview">
                        <span className="skill-preview-icon">
                          <Icon name="skill-file" />
                        </span>
                        <div>
                          <strong>{preview.displayName}</strong>
                          <code>{preview.invocationName}</code>
                          <p>
                            {preview.description || t("skills.no_description")}
                          </p>
                          <small>
                            {t("skills.preview_size", {
                              files: preview.fileCount,
                              size: new Intl.NumberFormat().format(
                                preview.totalBytes,
                              ),
                            })}
                          </small>
                          <p>{t("skills.resource_context_notice")}</p>
                        </div>
                      </div>
                      <div className="skill-dialog-notice" role="status">
                        <strong>{t(`skills.effect.${preview.effect}`)}</strong>
                        <p>{t("skills.scope.personal")}</p>
                        <p>
                          {t(`skills.effect_body.${preview.effect}`, {
                            skill: preview.invocationName,
                          })}
                        </p>
                        {shadowsBuiltin && (
                          <p>{t("skills.effect_body.shadows_builtin")}</p>
                        )}
                        {importBlocker && <p>{importError(importBlocker)}</p>}
                      </div>
                      <section className="skill-definition">
                        <h3>{t("skills.detail.definition")}</h3>
                        <pre>{preview.definition}</pre>
                      </section>
                    </>
                  )}
                  {error && (
                    <p className="skill-dialog-error" role="alert">
                      {error}
                    </p>
                  )}
                </>
              ) : selected ? (
                <>
                  {selected.description && (
                    <Dialog.Description className="skill-detail-description">
                      {selected.description}
                    </Dialog.Description>
                  )}
                  {selected.enabled === false && (
                    <p className="skill-detail-status">
                      {t("skills.enablement.disabled")}
                    </p>
                  )}
                  {selectedAttention && (
                    <div className="skill-dialog-notice" role="status">
                      <strong>{t(`skills.status.${selectedAttention}`)}</strong>
                      {selected.issueCodes.map((code) => (
                        <p key={code}>{t(`skills.issue.${code}`)}</p>
                      ))}
                    </div>
                  )}
                  <SkillContent
                    key={skillRowIdentity(selected)}
                    asset={selected}
                    onDetail={onDetail}
                  />
                </>
              ) : null}
            </div>

            {selected && (error || notice || detailEnablementFailed) && (
              <div className="px-5 pb-3">
                {(error || detailEnablementFailed) && (
                  <p className="skill-dialog-error" role="alert">
                    {error || enablementError}
                  </p>
                )}
                {notice && (
                  <p className="skill-dialog-success" role="status">
                    {notice}
                  </p>
                )}
              </div>
            )}
            {(importOpen || showDetailActions) && (
              <footer data-detail={!importOpen || undefined}>
                {importOpen ? (
                  <>
                    {preview && (
                      <ImportMenu
                        label={t("skills.choose_again")}
                        disabled={busy || disabled}
                        onChoose={(kind, trigger) =>
                          void beginImport(
                            kind,
                            trigger,
                            reimportTarget ?? undefined,
                          )
                        }
                      />
                    )}
                    <span />
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={busy}
                      onClick={() => closeDialog()}
                    >
                      {t("common.cancel")}
                    </Button>
                    {preview && (
                      <Button
                        variant="primary"
                        size="sm"
                        disabled={busy || disabled || importBlocker !== null}
                        onClick={() => void commitImport()}
                      >
                        {busy
                          ? t("skills.working")
                          : t(`skills.effect.${preview.effect}`)}
                      </Button>
                    )}
                  </>
                ) : selected ? (
                  <>
                    {selected.canSetEnabled && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={
                          busy ||
                          disabled ||
                          enablementBusy ||
                          !catalog.revision
                        }
                        onClick={() =>
                          void setEnablementState(
                            selected,
                            selected.enabled ? "disabled" : "enabled",
                          )
                        }
                      >
                        {t(
                          selected.enabled
                            ? "skills.enablement.disable"
                            : "skills.enablement.enable",
                        )}
                      </Button>
                    )}
                    {selected.installId && selected.canRetry && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={busy}
                        onClick={() =>
                          void runMutation(() => onRetry(selected.installId!))
                        }
                      >
                        <Icon name="refresh" /> {t("skills.retry")}
                      </Button>
                    )}
                    <span />
                    {selected.installId && selected.canUninstall && (
                      <Button
                        ref={uninstallTrigger}
                        variant="danger"
                        size="sm"
                        disabled={busy || disabled}
                        onClick={() => setConfirmUninstall(true)}
                      >
                        <Icon name="trash" /> {t("skills.uninstall")}
                      </Button>
                    )}
                  </>
                ) : null}
              </footer>
            )}
          </Dialog.Popup>
        </Dialog.Portal>
        {selected?.installId && selected.canUninstall && !disabled && (
          <AlertDialog.Root
            open={confirmUninstall}
            onOpenChange={setConfirmUninstall}
          >
            <AlertDialog.Portal>
              <AlertDialog.Backdrop />
              <AlertDialog.Popup
                initialFocus={cancelUninstall}
                finalFocus={uninstallTrigger}
              >
                <AlertDialog.Title>
                  {t("skills.uninstall_confirm_title", {
                    skill: selected.displayName || selected.invocationName,
                  })}
                </AlertDialog.Title>
                <AlertDialog.Description>
                  {t("skills.uninstall_confirm")}
                </AlertDialog.Description>
                <div className="flex justify-end gap-2">
                  <Button
                    ref={cancelUninstall}
                    variant="secondary"
                    size="sm"
                    onClick={() => setConfirmUninstall(false)}
                  >
                    {t("common.cancel")}
                  </Button>
                  <Button
                    variant="danger"
                    size="sm"
                    onClick={() => {
                      setConfirmUninstall(false);
                      void runMutation(
                        () => onUninstall(selected.installId!),
                        true,
                      );
                    }}
                  >
                    <Icon name="trash" /> {t("skills.uninstall")}
                  </Button>
                </div>
              </AlertDialog.Popup>
            </AlertDialog.Portal>
          </AlertDialog.Root>
        )}
      </Dialog.Root>
    </section>
  );
}
