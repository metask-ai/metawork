import { useEffect, useMemo, useRef, useState } from "react";

import type {
  SkillDetailResult,
  SkillExportResult,
  SkillImportPreview,
  SkillManagementView,
  SkillMutationResult,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SelectField } from "../../components/ui/select.tsx";
import { useI18n } from "../../i18n/context.ts";

type Asset = SkillManagementView["assets"][number];
type ScopeFilter = "all" | "personal" | "project";
type ImportKind = "package" | "directory";
type ImportScope =
  | { kind: "personal" }
  | { kind: "project"; workspaceId: string; workspaceEpoch: string };

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

function sourceLabel(asset: Asset, t: ReturnType<typeof useI18n>["t"]) {
  if (asset.sourceKind === "local_package") return t("skills.source.package");
  if (asset.sourceKind === "local_directory")
    return t("skills.source.directory");
  return t("skills.source.external");
}

function scopeLabel(
  asset: Asset,
  workspaces: WorkspaceView[],
  t: ReturnType<typeof useI18n>["t"],
) {
  if (asset.scope.kind === "personal") return t("skills.scope.personal");
  if (asset.scope.kind === "external") return t("skills.scope.external");
  return (
    workspaces.find((workspace) => workspace.id === asset.scope.workspaceId)
      ?.displayName ?? t("skills.scope.project")
  );
}

function SkillCard({
  asset,
  workspaces,
  onOpen,
}: {
  asset: Asset;
  workspaces: WorkspaceView[];
  onOpen: (asset: Asset, trigger: HTMLElement) => void;
}) {
  const { t } = useI18n();
  const attention =
    asset.managementState === "pending_verification" ||
    asset.issueCodes.length > 0;
  return (
    <li>
      <button
        className="skill-card focus-ring"
        data-attention={attention}
        onClick={(event) => onOpen(asset, event.currentTarget)}
      >
        <span className="skill-card-icon" aria-hidden="true">
          <Icon name="skill-file" />
        </span>
        <span className="skill-card-copy">
          <span className="skill-card-heading">
            <strong>{asset.displayName || asset.invocationName}</strong>
            <Icon name="chevron-right" />
          </span>
          <span className="skill-card-description">
            {asset.description || t("skills.no_description")}
          </span>
          <span className="skill-card-meta">
            <span>{scopeLabel(asset, workspaces, t)}</span>
            <span>{sourceLabel(asset, t)}</span>
            {attention && (
              <span className="skill-card-attention">
                {asset.managementState === "pending_verification"
                  ? t("skills.status.pending")
                  : t("skills.status.issue")}
              </span>
            )}
          </span>
        </span>
      </button>
    </li>
  );
}

export function SkillsPage({
  management,
  workspaces,
  query,
  refreshing,
  disabled,
  onQuery,
  onRefresh,
  onChooseImport,
  onInstall,
  onReimport,
  onUninstall,
  onRetry,
  onExport,
  onDetail,
}: {
  management: SkillManagementView;
  workspaces: WorkspaceView[];
  query: string;
  refreshing: boolean;
  disabled: boolean;
  onQuery: (query: string) => void;
  onRefresh: () => void;
  onChooseImport: (kind: ImportKind) => Promise<SkillImportPreview>;
  onInstall: (
    previewId: string,
    scope: ImportScope,
    allowReplace: boolean,
  ) => Promise<SkillMutationResult>;
  onReimport: (
    installId: string,
    previewId: string,
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
  const [scopeFilter, setScopeFilter] = useState<ScopeFilter>("all");
  const [selected, setSelected] = useState<Asset | null>(null);
  const [detail, setDetail] = useState<SkillDetailResult | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [preview, setPreview] = useState<SkillImportPreview | null>(null);
  const [importScope, setImportScope] = useState("personal");
  const [reimportTarget, setReimportTarget] = useState<Asset | null>(null);
  const [replaceRequired, setReplaceRequired] = useState(false);
  const [busy, setBusy] = useState(false);
  const [detailLoading, setDetailLoading] = useState(false);
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const visibleAssets = useMemo(() => {
    const filtered = filterSkills(management.assets, query);
    return filtered.filter((asset) => {
      if (scopeFilter === "all") return true;
      if (scopeFilter === "personal") return asset.scope.kind === "personal";
      return asset.scope.kind === "project";
    });
  }, [management.assets, query, scopeFilter]);
  const attention = visibleAssets.filter(
    (asset) =>
      asset.managementState === "pending_verification" ||
      asset.issueCodes.length > 0,
  );
  const regular = visibleAssets.filter((asset) => !attention.includes(asset));
  const manualWorkspaces = workspaces.filter(
    (workspace) =>
      workspace.kind === "manual" && workspace.authorization === "available",
  );
  const drawerOpen = selected !== null || importOpen;

  useEffect(() => title.current?.focus(), []);

  useEffect(() => {
    if (!drawerOpen) return;
    const frame = window.requestAnimationFrame(() =>
      drawerHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [drawerOpen, selected?.installId]);

  useEffect(() => {
    if (!selected) return;
    const current = management.assets.find(
      (asset) =>
        asset.installId === selected.installId &&
        asset.invocationName === selected.invocationName,
    );
    if (current) setSelected(current);
    else closeDrawer(false);
    // closeDrawer deliberately depends only on the authoritative asset list.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [management.assets]);

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

  function closeDrawer(restoreFocus = true) {
    const trigger = drawerTrigger.current;
    setSelected(null);
    setDetail(null);
    setImportOpen(false);
    setPreview(null);
    setReimportTarget(null);
    setReplaceRequired(false);
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
    if (!asset.installId) return;
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

  function beginImport(trigger?: HTMLElement, target?: Asset) {
    rememberTrigger(trigger);
    setSelected(null);
    setImportOpen(true);
    setPreview(null);
    setReimportTarget(target ?? null);
    setReplaceRequired(false);
    setError(null);
    setNotice(null);
    setImportScope("personal");
  }

  async function choose(kind: ImportKind) {
    if (busy) return;
    setBusy(true);
    setError(null);
    setReplaceRequired(false);
    try {
      const chosen = await onChooseImport(kind);
      if (chosen.selected) setPreview(chosen);
    } catch {
      setError(t("skills.error.preview"));
    } finally {
      setBusy(false);
    }
  }

  function selectedScope(): ImportScope | null {
    if (importScope === "personal") return { kind: "personal" };
    const workspace = manualWorkspaces.find((item) => item.id === importScope);
    return workspace
      ? {
          kind: "project",
          workspaceId: workspace.id,
          workspaceEpoch: workspace.epoch,
        }
      : null;
  }

  async function commitImport(allowReplace = false) {
    if (!preview?.selected || busy) return;
    const scope = selectedScope();
    if (!scope && !reimportTarget) return;
    setBusy(true);
    setError(null);
    try {
      const result = reimportTarget?.installId
        ? await onReimport(reimportTarget.installId, preview.previewId)
        : await onInstall(preview.previewId, scope!, allowReplace);
      if (!result.accepted) {
        if (result.reason === "target_exists") {
          setReplaceRequired(true);
          return;
        }
        setError(t("skills.error.mutation"));
        return;
      }
      closeDrawer();
    } catch {
      setError(t("skills.error.mutation"));
    } finally {
      setBusy(false);
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
        setError(t("skills.error.export"));
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
      <section className="skill-group">
        <header>
          <h2>{label}</h2>
          <span>{assets.length}</span>
        </header>
        <ul className="skill-grid">
          {assets.map((asset) => (
            <SkillCard
              key={`${asset.scope.kind}:${asset.scope.workspaceId ?? ""}:${asset.installId ?? asset.skillId}`}
              asset={asset}
              workspaces={workspaces}
              onOpen={(item, trigger) => void openDetail(item, trigger)}
            />
          ))}
        </ul>
      </section>
    );
  }

  const unavailable = management.availability !== "ready";
  const empty = management.assets.length === 0;
  const noResults = !empty && visibleAssets.length === 0;

  return (
    <section className="skills-page" aria-labelledby="skills-title">
      <div className="skills-page-inner skill-center">
        <header className="skills-header">
          <div>
            <h1 id="skills-title" ref={title} tabIndex={-1}>
              {t("skills.title")}
            </h1>
            <p>{t("skills.subtitle")}</p>
          </div>
          <div className="skill-header-actions">
            <Button
              variant="secondary"
              size="sm"
              disabled={disabled || refreshing}
              onClick={onRefresh}
            >
              <Icon name="refresh" />
              {t(refreshing ? "skills.refreshing" : "skills.refresh")}
            </Button>
            <Button
              variant="primary"
              size="sm"
              disabled={disabled || unavailable}
              onClick={(event) => beginImport(event.currentTarget)}
            >
              <Icon name="upload" />
              {t("skills.import")}
            </Button>
          </div>
        </header>

        <div className="skill-toolbar">
          <label className="skills-search">
            <Icon name="search" />
            <span className="sr-only">{t("skills.search_label")}</span>
            <Input
              type="search"
              value={query}
              placeholder={t("skills.search_placeholder")}
              onChange={(event) => onQuery(event.target.value)}
            />
          </label>
          <div
            className="skill-scope-filter"
            aria-label={t("skills.filter.label")}
          >
            {(["all", "personal", "project"] as const).map((scope) => (
              <button
                key={scope}
                className="focus-ring"
                data-active={scopeFilter === scope}
                onClick={() => setScopeFilter(scope)}
              >
                {t(`skills.filter.${scope}`)}
              </button>
            ))}
          </div>
        </div>

        {unavailable ? (
          <div className="skill-empty-state">
            <span>
              <Icon name="warning" />
            </span>
            <h2>{t("skills.unavailable_title")}</h2>
            <p>{t("skills.unavailable_body")}</p>
          </div>
        ) : empty ? (
          <div className="skill-empty-state">
            <span>
              <Icon name="skill-file" />
            </span>
            <h2>{t("skills.empty_title")}</h2>
            <p>{t("skills.empty_body")}</p>
            <Button
              variant="primary"
              size="sm"
              disabled={disabled}
              onClick={(event) => beginImport(event.currentTarget)}
            >
              <Icon name="upload" />
              {t("skills.import_first")}
            </Button>
          </div>
        ) : noResults ? (
          <div className="skill-empty-state skill-empty-state-compact">
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
                  {!preview?.selected ? (
                    <div className="skill-import-choices">
                      <button
                        className="skill-import-choice focus-ring"
                        disabled={busy}
                        onClick={() => void choose("package")}
                      >
                        <span>
                          <Icon name="package" />
                        </span>
                        <strong>{t("skills.choose_package")}</strong>
                        <small>{t("skills.choose_package_body")}</small>
                      </button>
                      <button
                        className="skill-import-choice focus-ring"
                        disabled={busy}
                        onClick={() => void choose("directory")}
                      >
                        <span>
                          <Icon name="folder-up" />
                        </span>
                        <strong>{t("skills.choose_folder")}</strong>
                        <small>{t("skills.choose_folder_body")}</small>
                      </button>
                    </div>
                  ) : (
                    <>
                      <div className="skill-import-preview">
                        <span className="skill-card-icon">
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
                        </div>
                      </div>
                      {!reimportTarget && (
                        <label className="skill-import-scope">
                          <span>{t("skills.install_scope")}</span>
                          <SelectField
                            value={importScope}
                            onValueChange={setImportScope}
                            options={[
                              {
                                value: "personal",
                                label: t("skills.scope.personal"),
                              },
                              ...manualWorkspaces.map((workspace) => ({
                                value: workspace.id,
                                label: workspace.displayName,
                              })),
                            ]}
                            aria-label={t("skills.install_scope")}
                          />
                        </label>
                      )}
                      {replaceRequired && (
                        <div className="skill-drawer-notice" role="alert">
                          <strong>{t("skills.replace_title")}</strong>
                          <p>{t("skills.replace_body")}</p>
                        </div>
                      )}
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
                      <strong>{scopeLabel(selected, workspaces, t)}</strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.source")}</span>
                      <strong>{sourceLabel(selected, t)}</strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.status")}</span>
                      <strong>
                        {selected.managementState === "pending_verification"
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
                  {preview?.selected && (
                    <button
                      className="text-button focus-ring"
                      disabled={busy}
                      onClick={() => {
                        setPreview(null);
                        setReplaceRequired(false);
                      }}
                    >
                      {t("skills.choose_again")}
                    </button>
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
                  {preview?.selected && (
                    <Button
                      variant="primary"
                      size="sm"
                      disabled={busy}
                      onClick={() => void commitImport(replaceRequired)}
                    >
                      {busy
                        ? t("skills.working")
                        : replaceRequired
                          ? t("skills.replace")
                          : reimportTarget
                            ? t("skills.reimport")
                            : t("skills.install")}
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
                    <button
                      className="text-button focus-ring"
                      disabled={busy}
                      onClick={(event) =>
                        beginImport(event.currentTarget, selected)
                      }
                    >
                      <Icon name="refresh" /> {t("skills.reimport")}
                    </button>
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
