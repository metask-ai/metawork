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
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
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
            <Menu.Item onClick={() => onChoose("package", trigger.current)}>
              <Icon name="package" />
              {t("skills.choose_package")}
            </Menu.Item>
            <Menu.Item onClick={() => onChoose("directory", trigger.current)}>
              <Icon name="folder-up" />
              {t("skills.choose_folder")}
            </Menu.Item>
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

function sourceLabel(asset: Asset, t: ReturnType<typeof useI18n>["t"]) {
  if (asset.sourceKind === "local_package") return t("skills.source.package");
  if (asset.sourceKind === "local_directory")
    return t("skills.source.directory");
  return t("skills.source.external");
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
  const attention =
    asset.managementState === "recovery_required" ||
    asset.managementState === "pending_verification" ||
    asset.issueCodes.length > 0;
  return (
    <li className="skill-row" data-attention={attention}>
      <button
        className="skill-row-open focus-ring"
        onClick={(event) => onOpen(asset, event.currentTarget)}
      >
        <span className="skill-row-icon" aria-hidden="true">
          <Icon name="skill-file" />
        </span>
        <span className="skill-row-copy">
          <strong>{asset.displayName || asset.invocationName}</strong>
          <span className="skill-row-description">
            {asset.description || t("skills.no_description")}
          </span>
          <span className="skill-row-meta">
            {asset.invocationName && <code>/{asset.invocationName}</code>}
            {attention && (
              <span className="skill-row-attention">
                {asset.managementState === "recovery_required"
                  ? t("skills.status.recovery_required")
                  : asset.managementState === "pending_verification"
                    ? t("skills.status.pending")
                    : t("skills.status.issue")}
              </span>
            )}
          </span>
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
  const drawerHeading = useRef<HTMLHeadingElement>(null);
  const drawer = useRef<HTMLDivElement>(null);
  const drawerTrigger = useRef<HTMLElement | null>(null);
  const [selected, setSelected] = useState<Asset | null>(null);
  const [detail, setDetail] = useState<SkillDetailResult | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [preview, setPreview] = useState<PreparedImport | null>(null);
  const [reimportTarget, setReimportTarget] = useState<Asset | null>(null);
  const importAudience = useRef(0);
  const previewRef = useRef<PreparedImport | null>(null);
  previewRef.current = preview;
  const discardRef = useRef(onDiscardImport);
  discardRef.current = onDiscardImport;
  const [busy, setBusy] = useState(false);
  const [detailLoading, setDetailLoading] = useState(false);
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [enablementBusy, setEnablementBusy] = useState<string | null>(null);
  const [enablementError, setEnablementError] = useState<string | null>(null);

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
  const drawerOpen = selected !== null || importOpen;
  const refreshing = refreshRequest.busy || catalog.availability === "loading";

  async function setEnablementState(
    asset: Asset,
    state: "enabled" | "disabled",
  ) {
    if (
      !asset.canSetEnabled ||
      !asset.skillPolicyKey ||
      !asset.selectionRevision
    )
      return;
    if (!catalog.revision) return;
    setEnablementBusy(asset.skillPolicyKey);
    setEnablementError(null);
    try {
      const result = await onSetEnabled(
        asset.skillPolicyKey,
        state,
        catalog.revision,
        asset.selectionRevision,
      );
      if (!result.applied) setEnablementError(t("skills.error.enablement"));
    } catch {
      setEnablementError(t("skills.error.enablement"));
    } finally {
      setEnablementBusy(null);
    }
  }

  useEffect(() => title.current?.focus(), []);
  useEffect(() => {
    importAudience.current += 1;
    discardPreview();
    setImportOpen(false);
    setBusy(false);
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
    if (!drawerOpen) return;
    const frame = window.requestAnimationFrame(() =>
      drawerHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [drawerOpen, selected?.installId]);

  useEffect(() => {
    if (!selected) return;
    const selectedIdentity = skillRowIdentity(selected);
    const current = personalAssets.find(
      (asset) => skillRowIdentity(asset) === selectedIdentity,
    );
    if (current) setSelected(current);
    else closeDrawer(false);
    // closeDrawer deliberately follows the committed personal inventory.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [personalAssets]);

  useEffect(() => {
    if (!drawerOpen) return;
    function keydown(event: KeyboardEvent) {
      if (event.key === "Escape" && !busy) closeDrawer();
      if (event.key !== "Tab" || !drawer.current) return;
      const focusable = Array.from(
        drawer.current.querySelectorAll<HTMLElement>(
          'button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex="0"]',
        ),
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  });

  function rememberTrigger(trigger?: HTMLElement) {
    drawerTrigger.current =
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

  function closeDrawer(restoreFocus = true) {
    importAudience.current += 1;
    discardPreview();
    const trigger = drawerTrigger.current;
    setSelected(null);
    setDetail(null);
    setImportOpen(false);
    setPreview(null);
    setBusy(false);
    setReimportTarget(null);

    setDetailLoading(false);
    setConfirmUninstall(false);
    setNotice(null);
    setError(null);
    if (restoreFocus)
      window.requestAnimationFrame(() => {
        if (trigger?.isConnected) trigger.focus();
      });
  }

  async function openDetail(asset: Asset, trigger: HTMLElement) {
    rememberTrigger(trigger);
    setImportOpen(false);
    setSelected(asset);
    setDetail(null);
    setError(null);
    if (!asset.installId || asset.managementState === "recovery_required")
      return;
    setDetailLoading(true);
    try {
      setDetail(await onDetail(asset.installId));
    } catch {
      setDetail(null);
      setError(t("skills.error.detail"));
    } finally {
      setDetailLoading(false);
    }
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
    if (!trigger || !drawer.current?.contains(trigger))
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
      closeDrawer();
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
      if (close) closeDrawer();
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
              onOpen={(item, trigger) => void openDetail(item, trigger)}
              onSetState={(item, state) => void setEnablementState(item, state)}
              enablementBusy={
                enablementBusy === asset.skillPolicyKey &&
                enablementBusy !== null
              }
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
          <p className="skill-drawer-notice" role="status">
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
        {enablementError && (
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

      <Drawer.Root
        open={drawerOpen}
        onOpenChange={(open) => {
          if (!open && !busy) closeDrawer();
        }}
      >
        <Drawer.Portal>
          <Drawer.Backdrop className="skill-drawer-backdrop" />
          <Drawer.Popup
            ref={drawer}
            className="skill-drawer w-[min(500px,calc(100vw-28px))] max-[620px]:w-full bg-(--ui-surface-canvas) shadow-[-18px_0_54px_rgba(37,34,45,0.13)]"
            aria-labelledby="skill-drawer-title"
          >
            <header>
              <div>
                <small>
                  {importOpen
                    ? t("skills.import.eyebrow")
                    : t("skills.detail.eyebrow")}
                </small>
                <h2 id="skill-drawer-title" ref={drawerHeading} tabIndex={-1}>
                  {importOpen
                    ? reimportTarget
                      ? t("skills.reimport")
                      : t("skills.import")
                    : selected?.displayName || selected?.invocationName}
                </h2>
              </div>
              <button
                className="icon-button focus-ring"
                aria-label={t("common.close")}
                disabled={busy}
                onClick={() => closeDrawer()}
              >
                <Icon name="close" />
              </button>
            </header>

            <div className="skill-drawer-scroll">
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
                      <div className="skill-drawer-notice" role="status">
                        <strong>{t(`skills.effect.${preview.effect}`)}</strong>
                        <p>{t("skills.scope.personal")}</p>
                        <p>
                          {t(`skills.effect_body.${preview.effect}`, {
                            skill: preview.invocationName,
                          })}
                        </p>
                        {importBlocker && <p>{importError(importBlocker)}</p>}
                      </div>
                      <section className="skill-definition">
                        <h3>{t("skills.detail.definition")}</h3>
                        <pre>{preview.definition}</pre>
                      </section>
                    </>
                  )}
                  {error && (
                    <p className="skill-drawer-error" role="alert">
                      {error}
                    </p>
                  )}
                </>
              ) : selected ? (
                <>
                  <div className="skill-detail-summary">
                    <div>
                      <span>{t("skills.detail.invocation")}</span>
                      <code>{selected.invocationName}</code>
                    </div>
                    <div>
                      <span>{t("skills.detail.scope")}</span>
                      <strong>{t("skills.scope.personal")}</strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.source")}</span>
                      <strong>{sourceLabel(selected, t)}</strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.origin")}</span>
                      <strong>
                        {selected.origin
                          ? `${selected.origin.ecosystem === "agents" ? ".agents" : selected.origin.ecosystem} · ${t(selected.origin.scope === "personal" ? "skills.sources.scope.user" : "skills.sources.scope.workspace")}`
                          : t("skills.sources.unknown_origin")}
                      </strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.status")}</span>
                      <strong>
                        {selected.managementState === "recovery_required"
                          ? t("skills.status.recovery_required")
                          : selected.managementState === "pending_verification"
                            ? t("skills.status.pending")
                            : selected.issueCodes.length > 0
                              ? t("skills.status.issue")
                              : t("skills.status.ready")}
                      </strong>
                    </div>
                  </div>
                  {selected.description && (
                    <p className="skill-detail-description">
                      {selected.description}
                    </p>
                  )}
                  {selected.issueCodes.length > 0 && (
                    <div className="skill-drawer-notice" role="status">
                      <strong>{t("skills.issue_title")}</strong>
                      <p>{selected.issueCodes.join(" · ")}</p>
                    </div>
                  )}
                  <section className="skill-definition">
                    <h3>{t("skills.detail.definition")}</h3>
                    {selected.installId === null ? (
                      <p>{t("skills.detail.external_body")}</p>
                    ) : detailLoading ? (
                      <p>{t("skills.detail.loading")}</p>
                    ) : detail?.available ? (
                      <pre>{detail.definition}</pre>
                    ) : (
                      <p>{t("skills.detail.unavailable")}</p>
                    )}
                  </section>
                  {error && (
                    <p className="skill-drawer-error" role="alert">
                      {error}
                    </p>
                  )}
                  {notice && (
                    <p className="skill-drawer-success" role="status">
                      {notice}
                    </p>
                  )}
                  {confirmUninstall && (
                    <div className="skill-drawer-notice" role="alert">
                      <strong>{t("skills.uninstall_confirm_title")}</strong>
                      <p>{t("skills.uninstall_confirm")}</p>
                    </div>
                  )}
                </>
              ) : null}
            </div>

            <footer>
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
                    onClick={() => closeDrawer()}
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
              ) : selected?.installId ? (
                <>
                  {selected.canExport && (
                    <button
                      className="text-button focus-ring"
                      disabled={busy}
                      onClick={() => void runExport()}
                    >
                      <Icon name="download" /> {t("skills.export")}
                    </button>
                  )}
                  {selected.canReimport && (
                    <ImportMenu
                      label={t("skills.reimport")}
                      disabled={busy || disabled}
                      onChoose={(kind, trigger) =>
                        void beginImport(kind, trigger, selected)
                      }
                    />
                  )}
                  {selected.canRetry && (
                    <button
                      className="text-button focus-ring"
                      disabled={busy}
                      onClick={() =>
                        void runMutation(() => onRetry(selected.installId!))
                      }
                    >
                      <Icon name="refresh" /> {t("skills.retry")}
                    </button>
                  )}
                  <span />
                  {selected.canUninstall &&
                    (confirmUninstall ? (
                      <>
                        <Button
                          variant="secondary"
                          size="sm"
                          disabled={busy}
                          onClick={() => setConfirmUninstall(false)}
                        >
                          {t("common.cancel")}
                        </Button>
                        <Button
                          variant="danger"
                          size="sm"
                          disabled={busy}
                          onClick={() =>
                            void runMutation(
                              () => onUninstall(selected.installId!),
                              true,
                            )
                          }
                        >
                          <Icon name="trash" /> {t("skills.uninstall")}
                        </Button>
                      </>
                    ) : (
                      <Button
                        variant="danger"
                        size="sm"
                        disabled={busy}
                        onClick={() => setConfirmUninstall(true)}
                      >
                        <Icon name="trash" /> {t("skills.uninstall")}
                      </Button>
                    ))}
                </>
              ) : (
                <>
                  <span />
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => closeDrawer()}
                  >
                    {t("common.close")}
                  </Button>
                </>
              )}
            </footer>
          </Drawer.Popup>
        </Drawer.Portal>
      </Drawer.Root>
    </section>
  );
}
