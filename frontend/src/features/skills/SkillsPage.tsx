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
  SkillSourceBrand,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SearchField } from "../../components/ui/search-field.tsx";
import { SelectField } from "../../components/ui/select.tsx";
import { Switch } from "../../components/ui/switch.tsx";
import { useI18n } from "../../i18n/context.ts";
import { SkillSourceControls } from "./SkillSourceControls.tsx";

type Asset = SkillManagementView["assets"][number];
export type SkillContext = "personal" | "project";
export type SkillRefreshTarget =
  | { scope: "personal" }
  | { scope: "project"; workspaceId: string; expectedWorkspaceEpoch: string };
export function skillRefreshKey(target: SkillRefreshTarget): string {
  return target.scope === "personal"
    ? "personal"
    : `project:${target.workspaceId}:${target.expectedWorkspaceEpoch}`;
}
export type SkillRefreshRequests = Record<
  string,
  { busy: boolean; error: string | null }
>;
type ImportKind = "package" | "directory";
type PreparedImport = Extract<SkillImportPreview, { status: "prepared" }>;

function ImportMenu({
  label,
  disabled,
  onChoose,
}: {
  label: string;
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
        render={<Button variant="primary" size="sm" />}
      >
        <Icon name="upload" />
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

export function skillWorkspaceKey(
  workspace: Pick<WorkspaceView, "id" | "epoch">,
): string {
  return `${workspace.id}:${workspace.epoch}`;
}

export function availableSkillWorkspaces(
  workspaces: WorkspaceView[],
): WorkspaceView[] {
  return workspaces.filter(
    (workspace) =>
      workspace.kind === "manual" && workspace.authorization === "available",
  );
}

export function resolveSkillWorkspace(
  workspaces: WorkspaceView[],
  selectedKey: string | null,
): WorkspaceView | null {
  const available = availableSkillWorkspaces(workspaces);
  return (
    available.find(
      (workspace) => skillWorkspaceKey(workspace) === selectedKey,
    ) ??
    available[0] ??
    null
  );
}

export function rowsForSkillContext(
  assets: Asset[],
  context: SkillContext,
  workspace: Pick<WorkspaceView, "id" | "epoch"> | null,
): Asset[] {
  if (context === "personal")
    return assets.filter((asset) => asset.scope.kind === "personal");
  // Ownership is keyed by Workspace id; the current epoch comes from the
  // Workspace itself when a command needs it.
  if (!workspace) return [];
  return assets.filter(
    (asset) =>
      asset.scope.kind === "project" &&
      asset.scope.workspaceId === workspace.id,
  );
}

function skillRowIdentity(asset: Asset): string {
  const scopeIdentity =
    asset.scope.kind === "project"
      ? `${asset.scope.kind}:${asset.scope.workspaceId}`
      : asset.scope.kind;
  return `${scopeIdentity}:${asset.installId ?? ""}:${asset.skillId ?? ""}:${asset.invocationName}`;
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
  const workspace = workspaces.find(
    (candidate) => candidate.id === asset.scope.workspaceId,
  );
  return workspace
    ? t("skills.scope.project_context", { workspace: workspace.displayName })
    : t("skills.scope.project");
}

function SkillCard({
  asset,
  workspaces,
  onOpen,
  onSetState,
  enablementBusy,
}: {
  asset: Asset;
  workspaces: WorkspaceView[];
  onOpen: (asset: Asset, trigger: HTMLElement) => void;
  onSetState: (asset: Asset, state: "inherit" | "enabled" | "disabled") => void;
  enablementBusy: boolean;
}) {
  const { t } = useI18n();
  const attention =
    asset.managementState === "recovery_required" ||
    asset.managementState === "pending_verification" ||
    asset.issueCodes.length > 0;
  return (
    <li className="skill-card" data-attention={attention}>
      <button
        className="skill-card-open focus-ring"
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
        <span className="skill-card-enablement">
          <span>
            {asset.scope.kind === "project" &&
            asset.enablementState === "inherit"
              ? t("skills.enablement.inherit")
              : asset.enabled
                ? t("skills.enablement.enabled")
                : t("skills.enablement.disabled")}
          </span>
          {asset.scope.kind === "project" &&
            asset.enablementState !== "inherit" && (
              <button
                className="skill-enablement-inherit focus-ring"
                disabled={!asset.canSetEnabled || enablementBusy}
                onClick={() => onSetState(asset, "inherit")}
              >
                {t("skills.enablement.follow_user")}
              </button>
            )}
          <Switch.Root
            checked={asset.enabled}
            disabled={!asset.canSetEnabled || enablementBusy}
            aria-label={t("skills.enablement.label", {
              skill: asset.displayName || asset.invocationName,
            })}
            onCheckedChange={(checked) =>
              onSetState(asset, checked ? "enabled" : "disabled")
            }
          >
            <Switch.Thumb />
          </Switch.Root>
        </span>
      )}
    </li>
  );
}

export function SkillsPage({
  management,
  personalCatalog,
  workspaces,
  query,
  refreshRequests,
  sourceBusy,
  sourceError,
  onSetSourceEnabled,
  onRecoverSources,
  disabled,
  onQuery,
  onRefresh,
  onSetEnabled,
  onChooseImport,
  onPrepareImport,
  onInstall,
  onReimport,
  onUninstall,
  onRetry,
  onExport,
  onDetail,
}: {
  management: SkillManagementView;
  personalCatalog: SkillCatalogView;
  workspaces: WorkspaceView[];
  query: string;
  refreshRequests: SkillRefreshRequests;
  sourceBusy: boolean;
  sourceError: string | null;
  onSetSourceEnabled: (
    id: SkillSourceBrand,
    enabled: boolean,
    revision: string,
  ) => void;
  onRecoverSources: (action: "reread" | "reset", token: string) => void;
  disabled: boolean;
  onQuery: (query: string) => void;
  onRefresh: (target: SkillRefreshTarget) => void;
  onSetEnabled: (
    target:
      | { scope: "personal" }
      | {
          scope: "project";
          workspaceId: string;
          expectedWorkspaceEpoch: string;
        },
    skillPolicyKey: string,
    state: "inherit" | "enabled" | "disabled",
    expectedCatalogRevision: string,
    expectedSelectionRevision: string,
  ) => Promise<SkillEnablementResult>;
  onChooseImport: (
    kind: ImportKind,
    target: SkillImportTarget,
  ) => Promise<SkillImportPreview>;
  onPrepareImport: (
    previewId: string,
    revision: string,
    target: SkillImportTarget | null,
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
  const [context, setContext] = useState<SkillContext>("personal");
  const [selectedWorkspaceKey, setSelectedWorkspaceKey] = useState<
    string | null
  >(null);
  const [selected, setSelected] = useState<Asset | null>(null);
  const [detail, setDetail] = useState<SkillDetailResult | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [preview, setPreview] = useState<PreparedImport | null>(null);
  const [importScope, setImportScope] = useState("personal");
  const [reimportTarget, setReimportTarget] = useState<Asset | null>(null);
  const importAudience = useRef(0);
  const previewRef = useRef<PreparedImport | null>(null);
  previewRef.current = preview;
  const discardRef = useRef(onPrepareImport);
  discardRef.current = onPrepareImport;
  const [busy, setBusy] = useState(false);
  const [detailLoading, setDetailLoading] = useState(false);
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [enablementBusy, setEnablementBusy] = useState<string | null>(null);
  const [enablementError, setEnablementError] = useState<string | null>(null);

  const manualWorkspaces = useMemo(
    () => availableSkillWorkspaces(workspaces),
    [workspaces],
  );
  const selectedWorkspace = useMemo(
    () => resolveSkillWorkspace(workspaces, selectedWorkspaceKey),
    [selectedWorkspaceKey, workspaces],
  );
  const effectiveWorkspaceKey = selectedWorkspace
    ? skillWorkspaceKey(selectedWorkspace)
    : null;
  const contextAssets = useMemo(
    () => rowsForSkillContext(management.assets, context, selectedWorkspace),
    [context, management.assets, selectedWorkspace],
  );
  const visibleAssets = useMemo(
    () => filterSkills(contextAssets, query),
    [contextAssets, query],
  );
  const attention = visibleAssets.filter(
    (asset) =>
      asset.managementState === "pending_verification" ||
      asset.managementState === "recovery_required",
  );
  const regular = visibleAssets.filter((asset) => !attention.includes(asset));
  const drawerOpen = selected !== null || importOpen;
  const catalog =
    context === "personal" ? personalCatalog : selectedWorkspace?.skillCatalog;
  const discovery =
    context === "personal"
      ? management.personalSourceDiscovery
      : (selectedWorkspace?.skillSourceDiscovery ?? null);
  const refreshTarget: SkillRefreshTarget | null =
    context === "personal"
      ? { scope: "personal" }
      : selectedWorkspace
        ? {
            scope: "project",
            workspaceId: selectedWorkspace.id,
            expectedWorkspaceEpoch: selectedWorkspace.epoch,
          }
        : null;
  const refreshRequest = refreshTarget
    ? refreshRequests[skillRefreshKey(refreshTarget)]
    : undefined;
  const refreshing =
    refreshRequest?.busy === true || catalog?.availability === "loading";
  const contextIdentity = refreshTarget
    ? skillRefreshKey(refreshTarget)
    : "project:none";
  const currentContextIdentity = useRef(contextIdentity);
  currentContextIdentity.current = contextIdentity;

  async function setEnablementState(
    asset: Asset,
    state: "inherit" | "enabled" | "disabled",
  ) {
    if (
      !asset.canSetEnabled ||
      !asset.skillPolicyKey ||
      !asset.selectionRevision
    )
      return;
    // Commands carry the Workspace's current epoch from the same snapshot,
    // never the asset's creation epoch.
    const currentWorkspace =
      asset.scope.kind === "project"
        ? workspaces.find(
            (candidate) => candidate.id === asset.scope.workspaceId,
          )
        : undefined;
    const target =
      asset.scope.kind === "project"
        ? currentWorkspace
          ? {
              scope: "project" as const,
              workspaceId: currentWorkspace.id,
              expectedWorkspaceEpoch: currentWorkspace.epoch,
            }
          : null
        : asset.scope.kind === "personal"
          ? { scope: "personal" as const }
          : null;
    if (!target || (target.scope === "personal" && state === "inherit")) return;
    const catalog =
      target.scope === "personal"
        ? personalCatalog
        : currentWorkspace?.skillCatalog;
    if (!catalog?.revision) return;
    const identity = `${target.scope}:${target.scope === "project" ? target.workspaceId : "user"}:${asset.skillPolicyKey}`;
    setEnablementBusy(identity);
    setEnablementError(null);
    const requestContext = contextIdentity;
    try {
      const result = await onSetEnabled(
        target,
        asset.skillPolicyKey,
        state,
        catalog.revision,
        asset.selectionRevision,
      );
      if (!result.applied && currentContextIdentity.current === requestContext)
        setEnablementError(t("skills.error.enablement"));
    } catch {
      if (currentContextIdentity.current === requestContext)
        setEnablementError(t("skills.error.enablement"));
    } finally {
      setEnablementBusy(null);
    }
  }

  useEffect(() => title.current?.focus(), []);
  useEffect(() => setEnablementError(null), [contextIdentity]);
  useEffect(() => {
    importAudience.current += 1;
    discardPreview();
    setImportOpen(false);
    setBusy(false);
  }, [contextIdentity, disabled]);
  useEffect(
    () => () => {
      importAudience.current += 1;
      const current = previewRef.current;
      if (current)
        void discardRef
          .current(current.previewId, current.preparationRevision, null)
          .catch(() => {});
    },
    [],
  );

  useEffect(() => {
    if (selectedWorkspaceKey !== effectiveWorkspaceKey)
      setSelectedWorkspaceKey(effectiveWorkspaceKey);
  }, [effectiveWorkspaceKey, selectedWorkspaceKey]);

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
    const current = contextAssets.find(
      (asset) => skillRowIdentity(asset) === selectedIdentity,
    );
    if (current) setSelected(current);
    else closeDrawer(false);
    // closeDrawer deliberately follows the authoritative current context.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contextAssets]);

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
        .current(current.previewId, current.preparationRevision, null)
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
    const requestContext = contextIdentity;
    const intent: SkillImportTarget | null = target?.installId
      ? { kind: "reimport", installId: target.installId }
      : context === "personal"
        ? { kind: "personal" }
        : selectedWorkspace
          ? {
              kind: "project",
              workspaceId: selectedWorkspace.id,
              workspaceEpoch: selectedWorkspace.epoch,
            }
          : null;
    if (!intent) return;
    setSelected(null);
    setImportOpen(false);
    setReimportTarget(target ?? null);
    setImportScope(intent.kind === "project" ? intent.workspaceId : "personal");
    setError(null);
    setNotice(null);
    setBusy(true);
    try {
      const chosen = await onChooseImport(kind, intent);
      if (
        audience !== importAudience.current ||
        requestContext !== currentContextIdentity.current
      ) {
        if (chosen.status === "prepared")
          void onPrepareImport(
            chosen.previewId,
            chosen.preparationRevision,
            null,
          ).catch(() => {});
        return;
      }
      if (chosen.status === "cancelled") return;
      setImportOpen(true);
      if (chosen.status === "rejected") {
        setError(importError(chosen.reason));
        return;
      }
      setPreview(chosen);
      setImportScope(
        chosen.scope.kind === "project" ? chosen.scope.workspaceId : "personal",
      );
    } catch {
      if (audience === importAudience.current) {
        setImportOpen(true);
        setError(t("skills.error.preview"));
      }
    } finally {
      if (audience === importAudience.current) setBusy(false);
    }
  }

  async function changeImportScope(value: string) {
    if (!preview || busy || disabled) return;
    const workspace = manualWorkspaces.find((item) => item.id === value);
    const target: SkillImportTarget | null =
      value === "personal"
        ? { kind: "personal" }
        : workspace
          ? {
              kind: "project",
              workspaceId: workspace.id,
              workspaceEpoch: workspace.epoch,
            }
          : null;
    if (!target) return;
    const audience = ++importAudience.current;
    setBusy(true);
    setError(null);
    try {
      const result = await onPrepareImport(
        preview.previewId,
        preview.preparationRevision,
        target,
      );
      if (audience !== importAudience.current) return;
      if (result.status === "prepared") {
        setPreview(result);
        setImportScope(
          result.scope.kind === "project"
            ? result.scope.workspaceId
            : "personal",
        );
      } else if (result.status === "rejected") {
        setError(importError(result.reason));
        if (
          !["busy", "capacity_reached", "catalog_loading"].includes(
            result.reason,
          )
        )
          discardPreview();
      }
    } catch {
      if (audience === importAudience.current) {
        discardPreview();
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
      <section className="skill-group">
        <header>
          <h2>{label}</h2>
          <span>{assets.length}</span>
        </header>
        <ul className="skill-grid">
          {assets.map((asset) => (
            <SkillCard
              key={skillRowIdentity(asset)}
              asset={asset}
              workspaces={workspaces}
              onOpen={(item, trigger) => void openDetail(item, trigger)}
              onSetState={(item, state) => void setEnablementState(item, state)}
              enablementBusy={
                enablementBusy ===
                `${asset.scope.kind}:${asset.scope.kind === "project" ? asset.scope.workspaceId : "user"}:${asset.skillPolicyKey ?? ""}`
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
    (context === "personal"
      ? operation.scope.kind === "personal"
      : operation.scope.kind === "project" &&
        operation.scope.workspaceId === selectedWorkspace?.id &&
        operation.scope.workspaceEpoch === selectedWorkspace?.epoch)
      ? operation
      : null;

  const unavailable = management.availability !== "ready";
  const missingProjectWorkspace =
    context === "project" && selectedWorkspace === null;
  const empty = contextAssets.length === 0;
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
              disabled={
                disabled ||
                refreshing ||
                !refreshTarget ||
                management.sourceSettings.revision === null
              }
              onClick={() => {
                if (refreshTarget) onRefresh(refreshTarget);
              }}
            >
              <Icon name="refresh" />
              {t(refreshing ? "skills.refreshing" : "skills.refresh")}
            </Button>
            <ImportMenu
              label={t("skills.import")}
              disabled={
                disabled ||
                unavailable ||
                busy ||
                (context === "project" && !selectedWorkspace)
              }
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

        <SkillSourceControls
          settings={management.sourceSettings}
          discovery={discovery}
          contextLabel={
            context === "personal"
              ? t("skills.scope.personal")
              : (selectedWorkspace?.displayName ?? t("skills.no_project_title"))
          }
          busy={sourceBusy}
          error={sourceError}
          disabled={disabled}
          onSetEnabled={onSetSourceEnabled}
          onRecover={onRecoverSources}
        />

        <div className="skill-toolbar">
          <SearchField
            className="max-w-[360px] flex-1"
            label={t("skills.search_label")}
            value={query}
            placeholder={t("skills.search_placeholder")}
            onChange={(event) => onQuery(event.target.value)}
          />
          <div className="skill-context-controls">
            <div
              className="skill-scope-filter"
              aria-label={t("skills.filter.label")}
            >
              {(["personal", "project"] as const).map((nextContext) => (
                <button
                  key={nextContext}
                  className="focus-ring"
                  data-active={context === nextContext}
                  onClick={() => {
                    if (context === nextContext) return;
                    closeDrawer(false);
                    setContext(nextContext);
                  }}
                >
                  {t(`skills.filter.${nextContext}`)}
                </button>
              ))}
            </div>
            {context === "project" && manualWorkspaces.length > 0 && (
              <SelectField
                className="skill-workspace-select"
                value={effectiveWorkspaceKey ?? ""}
                options={manualWorkspaces.map((workspace) => ({
                  value: skillWorkspaceKey(workspace),
                  label: workspace.displayName,
                }))}
                onValueChange={(workspaceKey) => {
                  if (workspaceKey === effectiveWorkspaceKey) return;
                  closeDrawer(false);
                  setSelectedWorkspaceKey(workspaceKey);
                }}
                aria-label={t("skills.project_workspace")}
              />
            )}
          </div>
        </div>

        {refreshRequest?.error && (
          <p className="skill-enablement-error" role="alert">
            {refreshRequest.error}
          </p>
        )}
        {catalog?.issues.length ? (
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
        {catalog &&
          !["ready", "degraded", "loading"].includes(catalog.availability) && (
            <p className="skill-enablement-error" role="status">
              {t("skills.catalog_unavailable")}
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
        ) : missingProjectWorkspace ? (
          <div className="skill-empty-state">
            <span>
              <Icon name="folder-up" />
            </span>
            <h2>{t("skills.no_project_title")}</h2>
            <p>{t("skills.no_project_body")}</p>
          </div>
        ) : empty && catalog?.availability === "loading" ? (
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
                catalog?.issues.length
                  ? "skills.no_available_title"
                  : "skills.empty_title",
              )}
            </h2>
            <p>
              {t(
                catalog?.issues.length
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
                          <p>{t("skills.resource_context_notice")}</p>
                        </div>
                      </div>
                      {!reimportTarget && (
                        <label className="skill-import-scope">
                          <span>{t("skills.install_scope")}</span>
                          <SelectField
                            value={importScope}
                            onValueChange={(value) =>
                              void changeImportScope(value)
                            }
                            disabled={busy || disabled}
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
                      <div className="skill-drawer-notice" role="status">
                        <strong>{t(`skills.effect.${preview.effect}`)}</strong>
                        <p>
                          {preview.scope.kind === "personal"
                            ? t("skills.scope.personal")
                            : t("skills.scope.project_context", {
                                workspace:
                                  workspaces.find(
                                    (w) => w.id === preview.scope.workspaceId,
                                  )?.displayName ?? t("skills.scope.project"),
                              })}
                        </p>
                        <p>{t(`skills.effect_body.${preview.effect}`)}</p>
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
                      <strong>{scopeLabel(selected, workspaces, t)}</strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.source")}</span>
                      <strong>{sourceLabel(selected, t)}</strong>
                    </div>
                    <div>
                      <span>{t("skills.detail.origin")}</span>
                      <strong>
                        {selected.origin
                          ? `${selected.origin.ecosystem === "agents" ? ".agents" : selected.origin.ecosystem === "claude" ? "Claude" : "Codex"} · ${t(selected.origin.scope === "personal" ? "skills.sources.scope.user" : "skills.sources.scope.workspace")}`
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
