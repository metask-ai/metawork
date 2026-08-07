import { useEffect, useMemo, useRef, useState } from "react";

import type {
  McpManagementView,
  McpMutationResult,
  McpRefreshResult,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

type McpServer = McpManagementView["servers"][number];
type DrawerState = { kind: "add" } | { kind: "server"; id: string } | null;
type ConfirmAction = "enable" | "disable" | "delete" | null;

const attentionStatuses = new Set<McpServer["runtimeStatus"]>([
  "not_loaded",
  "needs_authentication",
  "unreachable",
  "invalid_catalog",
]);

export function filterMcpServers(
  servers: McpServer[],
  query: string,
): McpServer[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return servers;
  return servers.filter((server) =>
    [
      server.displayName,
      server.namespace,
      server.transport,
      ...server.tools.map((tool) => tool.name),
    ].some((value) => value.toLocaleLowerCase().includes(needle)),
  );
}

export function validMcpHttpEndpoint(value: string): boolean {
  if (
    !/^https?:\/\//i.test(value) ||
    /[?#\r\n]/.test(value) ||
    new TextEncoder().encode(value).length > 4096
  )
    return false;
  const authority = value.slice(value.indexOf("://") + 3).split("/", 1)[0];
  if (authority.includes("@")) return false;
  try {
    const endpoint = new URL(value);
    if (
      endpoint.username ||
      endpoint.password ||
      endpoint.search ||
      endpoint.hash
    )
      return false;
    if (endpoint.protocol === "https:") return true;
    return (
      endpoint.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(endpoint.hostname)
    );
  } catch {
    return false;
  }
}

function validMcpDisplayName(value: string): boolean {
  const trimmed = value.trim();
  return trimmed.length > 0 && new TextEncoder().encode(trimmed).length <= 256;
}

function serverNeedsAttention(server: McpServer) {
  return (
    attentionStatuses.has(server.runtimeStatus) ||
    server.newTaskAccess === "restart_required" ||
    server.newTaskAccess === "unavailable"
  );
}

function serverStateKey(server: McpServer) {
  if (server.newTaskAccess === "restart_required")
    return "mcp.access.restart_required" as const;
  if (server.runtimeStatus !== "ready")
    return `mcp.status.${server.runtimeStatus}` as const;
  return `mcp.access.${server.newTaskAccess}` as const;
}

function serverStateIcon(server: McpServer) {
  if (serverNeedsAttention(server)) return "warning" as const;
  if (server.runtimeStatus === "ready") return "check" as const;
  return "mcp" as const;
}

function McpServerRow({
  server,
  onOpen,
}: {
  server: McpServer;
  onOpen: (server: McpServer, trigger: HTMLElement) => void;
}) {
  const { t } = useI18n();
  const available = server.tools.filter(
    (tool) => tool.availableToNewTasks,
  ).length;
  return (
    <li>
      <button
        className="mcp-server-row focus-ring"
        data-status={
          server.newTaskAccess === "restart_required"
            ? "restart_required"
            : server.runtimeStatus
        }
        onClick={(event) => onOpen(server, event.currentTarget)}
      >
        <span className="mcp-status-rail" aria-hidden="true" />
        <span className="mcp-server-identity">
          <strong>{server.displayName}</strong>
          <span>{server.namespace}</span>
        </span>
        <span className="mcp-server-transport">
          {t(`mcp.transport.${server.transport}`)}
        </span>
        <span className="mcp-server-tools">
          {t("mcp.tool_access_summary", {
            available,
            total: server.tools.length,
          })}
        </span>
        <span className="mcp-server-state">
          <Icon name={serverStateIcon(server)} />
          {t(serverStateKey(server))}
        </span>
        <Icon name="chevron-right" />
      </button>
    </li>
  );
}

export function McpPage({
  management,
  query,
  disabled,
  onQuery,
  onCreate,
  onRename,
  onSetEnabled,
  onSetAllowedTools,
  onRemove,
  onRefresh,
}: {
  management: McpManagementView;
  query: string;
  disabled: boolean;
  onQuery: (query: string) => void;
  onCreate: (
    expectedGeneration: string,
    displayName: string,
    endpoint: string,
  ) => Promise<McpMutationResult>;
  onRename: (
    expectedGeneration: string,
    serverId: string,
    displayName: string,
  ) => Promise<McpMutationResult>;
  onSetEnabled: (
    expectedGeneration: string,
    serverId: string,
    enabled: boolean,
  ) => Promise<McpMutationResult>;
  onSetAllowedTools: (
    expectedGeneration: string,
    serverId: string,
    toolNames: string[],
  ) => Promise<McpMutationResult>;
  onRemove: (
    expectedGeneration: string,
    serverId: string,
  ) => Promise<McpMutationResult>;
  onRefresh: () => Promise<McpRefreshResult>;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const drawer = useRef<HTMLElement>(null);
  const drawerHeading = useRef<HTMLHeadingElement>(null);
  const confirmPanel = useRef<HTMLDivElement>(null);
  const confirmHeading = useRef<HTMLHeadingElement>(null);
  const confirmTrigger = useRef<HTMLElement | null>(null);
  const drawerTrigger = useRef<HTMLElement | null>(null);
  const [drawerState, setDrawerState] = useState<DrawerState>(null);
  const [confirmAction, setConfirmAction] = useState<ConfirmAction>(null);
  const [pendingServerId, setPendingServerId] = useState<string | null>(null);
  const [createPending, setCreatePending] = useState(false);
  const [refreshPending, setRefreshPending] = useState(false);
  const [displayName, setDisplayName] = useState("");
  const [endpoint, setEndpoint] = useState("");
  const [renameDraft, setRenameDraft] = useState("");
  const [notice, setNotice] = useState<{
    tone: "quiet" | "attention";
    text: string;
  } | null>(null);

  const visibleServers = useMemo(
    () => filterMcpServers(management.servers, query),
    [management.servers, query],
  );
  const selected =
    drawerState?.kind === "server"
      ? (management.servers.find((server) => server.id === drawerState.id) ??
        null)
      : null;
  const attention = visibleServers.filter(serverNeedsAttention);
  const available = visibleServers.filter(
    (server) => !serverNeedsAttention(server) && server.desiredEnabled,
  );
  const disabledServers = visibleServers.filter(
    (server) => !serverNeedsAttention(server) && !server.desiredEnabled,
  );
  const managementReady = management.managementHealth === "ready";
  const mutationLocked =
    disabled ||
    !managementReady ||
    management.operation !== "idle" ||
    management.desiredGeneration === null ||
    management.runtimeAlignment === "unknown" ||
    refreshPending;
  const refreshLocked =
    disabled ||
    !managementReady ||
    management.operation !== "idle" ||
    management.availability === "unavailable" ||
    refreshPending ||
    createPending ||
    pendingServerId !== null;
  const addValid =
    validMcpDisplayName(displayName) && validMcpHttpEndpoint(endpoint.trim());

  useEffect(() => title.current?.focus(), []);

  useEffect(() => {
    if (!drawerState) return;
    const frame = window.requestAnimationFrame(() =>
      drawerHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [drawerState?.kind, selected?.id]);

  useEffect(() => {
    if (drawerState?.kind === "server" && !selected) setDrawerState(null);
  }, [drawerState, selected]);

  useEffect(() => {
    if (selected) setRenameDraft(selected.displayName);
  }, [selected?.id, selected?.displayName]);

  useEffect(() => {
    if (!confirmAction) return;
    const frame = window.requestAnimationFrame(() =>
      confirmHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [confirmAction]);

  useEffect(() => {
    if (!drawerState) return;
    function keydown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        if (confirmAction) closeConfirmation();
        else closeDrawer();
      }
      const focusScope = confirmAction ? confirmPanel.current : drawer.current;
      if (event.key !== "Tab" || !focusScope) return;
      const focusable = Array.from(
        focusScope.querySelectorAll<HTMLElement>(
          'button:not(:disabled), input:not(:disabled), [tabindex="0"]',
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

  function openServer(server: McpServer, trigger: HTMLElement) {
    drawerTrigger.current = trigger;
    setConfirmAction(null);
    setNotice(null);
    setDrawerState({ kind: "server", id: server.id });
  }

  function openAdd(trigger: HTMLElement) {
    drawerTrigger.current = trigger;
    setDisplayName("");
    setEndpoint("");
    setNotice(null);
    setDrawerState({ kind: "add" });
  }

  function closeDrawer() {
    const trigger = drawerTrigger.current;
    setDrawerState(null);
    setConfirmAction(null);
    confirmTrigger.current = null;
    window.requestAnimationFrame(() => {
      if (trigger?.isConnected) trigger.focus();
    });
  }

  function openConfirmation(
    action: Exclude<ConfirmAction, null>,
    trigger: HTMLElement,
  ) {
    confirmTrigger.current = trigger;
    setConfirmAction(action);
  }

  function closeConfirmation() {
    const trigger = confirmTrigger.current;
    setConfirmAction(null);
    confirmTrigger.current = null;
    window.requestAnimationFrame(() => {
      if (trigger?.isConnected) trigger.focus();
    });
  }

  function acceptConfirmation() {
    setConfirmAction(null);
    confirmTrigger.current = null;
    window.requestAnimationFrame(() => drawerHeading.current?.focus());
  }

  function mutationNotice(result: McpMutationResult) {
    const attention = [
      "saved_recovery_required",
      "stale_generation",
      "rejected",
      "indeterminate",
    ].includes(result.outcome);
    setNotice({
      tone: attention ? "attention" : "quiet",
      text: t(`mcp.mutation.${result.outcome}`),
    });
  }

  async function createServer() {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || !addValid || createPending) return;
    setCreatePending(true);
    setNotice(null);
    try {
      const result = await onCreate(
        generation,
        displayName.trim(),
        endpoint.trim(),
      );
      mutationNotice(result);
      if (
        result.outcome === "saved" ||
        result.outcome === "saved_recovery_required"
      )
        closeDrawer();
    } catch {
      setNotice({ tone: "attention", text: t("mcp.mutation.failed") });
    } finally {
      setCreatePending(false);
    }
  }

  async function mutateServer(
    server: McpServer,
    mutation: (generation: string) => Promise<McpMutationResult>,
  ) {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || pendingServerId === server.id) return;
    setPendingServerId(server.id);
    setNotice(null);
    try {
      const result = await mutation(generation);
      mutationNotice(result);
      return result;
    } catch {
      setNotice({ tone: "attention", text: t("mcp.mutation.failed") });
      return null;
    } finally {
      setPendingServerId(null);
    }
  }

  async function refreshCatalog() {
    if (refreshLocked) return;
    setRefreshPending(true);
    setNotice(null);
    try {
      const result = await onRefresh();
      setNotice({
        tone: result.outcome === "started" ? "quiet" : "attention",
        text: t(`mcp.refresh.${result.outcome}`),
      });
    } catch {
      setNotice({ tone: "attention", text: t("mcp.refresh.failed") });
    } finally {
      setRefreshPending(false);
    }
  }

  function renderGroup(label: string, servers: McpServer[]) {
    if (servers.length === 0) return null;
    return (
      <section className="mcp-group">
        <header>
          <h2>{label}</h2>
          <span>{servers.length}</span>
        </header>
        <ul className="mcp-server-list">
          {servers.map((server) => (
            <McpServerRow key={server.id} server={server} onOpen={openServer} />
          ))}
        </ul>
      </section>
    );
  }

  function renderBanner() {
    if (management.managementHealth === "outcome_unknown")
      return (
        <div className="mcp-state-banner" data-tone="danger">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.outcome_unknown.title")}</strong>
            <p>{t("mcp.banner.outcome_unknown.body")}</p>
          </div>
        </div>
      );
    if (management.managementHealth === "recovery_required")
      return (
        <div className="mcp-state-banner" data-tone="warning">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.recovery.title")}</strong>
            <p>{t("mcp.banner.recovery.body")}</p>
          </div>
        </div>
      );
    if (management.runtimeAlignment === "restart_required")
      return (
        <div className="mcp-state-banner" data-tone="warning">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.restart.title")}</strong>
            <p>{t("mcp.banner.restart.body")}</p>
          </div>
        </div>
      );
    if (management.runtimeAlignment === "unknown" && managementReady)
      return (
        <div className="mcp-state-banner" data-tone="warning">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.alignment_unknown.title")}</strong>
            <p>{t("mcp.banner.alignment_unknown.body")}</p>
          </div>
        </div>
      );
    if (management.availability === "unavailable" && managementReady)
      return (
        <div className="mcp-state-banner" data-tone="neutral">
          <Icon name="mcp" />
          <div>
            <strong>{t("mcp.banner.runtime_unavailable.title")}</strong>
            <p>{t("mcp.banner.runtime_unavailable.body")}</p>
          </div>
        </div>
      );
    return null;
  }

  const empty = management.servers.length === 0;
  const noResults = !empty && visibleServers.length === 0;
  const unavailable = management.managementHealth === "unavailable";
  const frozenWithoutDesired =
    management.desiredGeneration === null && !unavailable;

  return (
    <section className="mcp-page" aria-labelledby="mcp-title">
      <div className="mcp-page-inner">
        <header className="mcp-header">
          <div>
            <h1 id="mcp-title" ref={title} tabIndex={-1}>
              {t("mcp.title")}
            </h1>
            <p>{t("mcp.subtitle")}</p>
          </div>
          <div className="mcp-header-actions">
            {management.desiredGeneration && (
              <span className="mcp-catalog-revision">
                {t("mcp.desired_generation", {
                  generation: management.desiredGeneration,
                })}
              </span>
            )}
            <button
              className="primary-button focus-ring"
              disabled={mutationLocked}
              onClick={(event) => openAdd(event.currentTarget)}
            >
              <Icon name="plus" />
              {t("mcp.add.action")}
            </button>
          </div>
        </header>

        {renderBanner()}

        {notice && (
          <p
            className="mcp-operation-notice"
            data-tone={notice.tone}
            aria-live="polite"
          >
            {notice.text}
          </p>
        )}

        {!unavailable &&
          !frozenWithoutDesired &&
          (!empty || managementReady) && (
            <div className="mcp-toolbar">
              <label className="mcp-search">
                <Icon name="search" />
                <span className="sr-only">{t("mcp.search_label")}</span>
                <input
                  type="search"
                  value={query}
                  placeholder={t("mcp.search_placeholder")}
                  onChange={(event) => onQuery(event.target.value)}
                />
              </label>
              <button
                className="secondary-button focus-ring"
                disabled={refreshLocked}
                onClick={() => void refreshCatalog()}
              >
                <Icon name="refresh" />
                {refreshPending || management.operation === "refreshing"
                  ? t("mcp.refresh.refreshing")
                  : t("mcp.refresh.action")}
              </button>
            </div>
          )}

        {unavailable ? (
          <div className="mcp-empty-state">
            <span>
              <Icon name="warning" />
            </span>
            <h2>{t("mcp.unavailable_title")}</h2>
            <p>{t("mcp.unavailable_body")}</p>
          </div>
        ) : frozenWithoutDesired ? null : empty ? (
          <div className="mcp-empty-state">
            <span>
              <Icon name="mcp" />
            </span>
            <h2>{t("mcp.empty_title")}</h2>
            <p>{t("mcp.empty_body")}</p>
            <button
              className="primary-button focus-ring"
              disabled={mutationLocked}
              onClick={(event) => openAdd(event.currentTarget)}
            >
              <Icon name="plus" />
              {t("mcp.add.action")}
            </button>
          </div>
        ) : noResults ? (
          <div className="mcp-empty-state mcp-empty-state-compact">
            <span>
              <Icon name="search" />
            </span>
            <h2>{t("mcp.no_results_title")}</h2>
            <p>{t("mcp.no_results_body", { query: query.trim() })}</p>
          </div>
        ) : (
          <div className="mcp-groups">
            {renderGroup(t("mcp.section.attention"), attention)}
            {renderGroup(t("mcp.section.available"), available)}
            {renderGroup(t("mcp.section.disabled"), disabledServers)}
          </div>
        )}
      </div>

      {drawerState && (
        <div
          className="mcp-drawer-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeDrawer();
          }}
        >
          <aside
            ref={drawer}
            className="mcp-drawer"
            role="dialog"
            aria-modal="true"
            aria-labelledby="mcp-drawer-title"
          >
            <header>
              <div>
                <small>
                  {drawerState.kind === "add"
                    ? t("mcp.add.eyebrow")
                    : t("mcp.detail.eyebrow")}
                </small>
                <h2 id="mcp-drawer-title" ref={drawerHeading} tabIndex={-1}>
                  {drawerState.kind === "add"
                    ? t("mcp.add.title")
                    : selected?.displayName}
                </h2>
                {selected && <p>{selected.namespace}</p>}
              </div>
              <button
                className="icon-button focus-ring"
                aria-label={t("common.close")}
                onClick={closeDrawer}
              >
                <Icon name="close" />
              </button>
            </header>

            {drawerState.kind === "add" ? (
              <form
                className="mcp-add-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  void createServer();
                }}
              >
                <p className="mcp-form-intro">{t("mcp.add.intro")}</p>
                <label>
                  <span>{t("mcp.add.name")}</span>
                  <input
                    autoComplete="off"
                    value={displayName}
                    maxLength={256}
                    disabled={createPending}
                    onChange={(event) => setDisplayName(event.target.value)}
                  />
                </label>
                <label>
                  <span id="mcp-add-endpoint-label">
                    {t("mcp.add.endpoint")}
                  </span>
                  <input
                    autoComplete="off"
                    inputMode="url"
                    placeholder="https://mcp.example.com"
                    value={endpoint}
                    maxLength={4096}
                    disabled={createPending}
                    aria-labelledby="mcp-add-endpoint-label"
                    aria-describedby="mcp-add-endpoint-help"
                    aria-invalid={
                      endpoint.length > 0 && !validMcpHttpEndpoint(endpoint)
                    }
                    onChange={(event) => setEndpoint(event.target.value)}
                  />
                  <small id="mcp-add-endpoint-help">
                    {t("mcp.add.endpoint_help")}
                  </small>
                </label>
                <div className="mcp-add-defaults">
                  <Icon name="check" />
                  <p>{t("mcp.add.defaults")}</p>
                </div>
                <footer>
                  <button
                    type="button"
                    className="secondary-button focus-ring"
                    onClick={closeDrawer}
                  >
                    {t("common.cancel")}
                  </button>
                  <button
                    type="submit"
                    className="primary-button focus-ring"
                    disabled={!addValid || mutationLocked || createPending}
                  >
                    {createPending ? t("mcp.add.adding") : t("mcp.add.submit")}
                  </button>
                </footer>
              </form>
            ) : selected ? (
              <div className="mcp-detail-body">
                <dl className="mcp-authority-strip">
                  <div>
                    <dt>{t("mcp.detail.desired")}</dt>
                    <dd>
                      {selected.desiredEnabled
                        ? t("mcp.desired.enabled")
                        : t("mcp.desired.disabled")}
                    </dd>
                  </div>
                  <div>
                    <dt>{t("mcp.detail.runtime")}</dt>
                    <dd data-status={selected.runtimeStatus}>
                      {t(`mcp.status.${selected.runtimeStatus}`)}
                    </dd>
                  </div>
                  <div>
                    <dt>{t("mcp.detail.new_tasks")}</dt>
                    <dd data-access={selected.newTaskAccess}>
                      {t(`mcp.access.${selected.newTaskAccess}`)}
                    </dd>
                  </div>
                </dl>

                {selected.safeDiagnostic && (
                  <section className="mcp-diagnostic">
                    <h3>{t("mcp.detail.diagnostic")}</h3>
                    <p>{selected.safeDiagnostic}</p>
                  </section>
                )}
                {management.redacted && (
                  <p className="mcp-redaction-notice">
                    <Icon name="warning" />
                    {t("mcp.redacted")}
                  </p>
                )}

                <section className="mcp-detail-section">
                  <header>
                    <div>
                      <h3>{t("mcp.detail.configuration")}</h3>
                      <p>{t(`mcp.transport.${selected.transport}`)}</p>
                    </div>
                  </header>
                  <form
                    className="mcp-rename-form"
                    onSubmit={(event) => {
                      event.preventDefault();
                      if (
                        !validMcpDisplayName(renameDraft) ||
                        renameDraft.trim() === selected.displayName
                      )
                        return;
                      void mutateServer(selected, (generation) =>
                        onRename(generation, selected.id, renameDraft.trim()),
                      );
                    }}
                  >
                    <label>
                      <span>{t("mcp.detail.display_name")}</span>
                      <input
                        value={renameDraft}
                        maxLength={256}
                        disabled={
                          mutationLocked || pendingServerId === selected.id
                        }
                        onChange={(event) => setRenameDraft(event.target.value)}
                      />
                    </label>
                    <button
                      className="secondary-button focus-ring"
                      disabled={
                        mutationLocked ||
                        pendingServerId === selected.id ||
                        !validMcpDisplayName(renameDraft) ||
                        renameDraft.trim() === selected.displayName
                      }
                    >
                      {t("mcp.rename.action")}
                    </button>
                  </form>
                  <div className="mcp-configuration-actions">
                    <button
                      className="secondary-button focus-ring"
                      disabled={
                        mutationLocked || pendingServerId === selected.id
                      }
                      onClick={(event) =>
                        openConfirmation(
                          selected.desiredEnabled ? "disable" : "enable",
                          event.currentTarget,
                        )
                      }
                    >
                      {selected.desiredEnabled
                        ? t("mcp.disable.action")
                        : t("mcp.enable.action")}
                    </button>
                    <button
                      className="danger-button focus-ring"
                      disabled={
                        mutationLocked || pendingServerId === selected.id
                      }
                      onClick={(event) =>
                        openConfirmation("delete", event.currentTarget)
                      }
                    >
                      <Icon name="trash" />
                      {t("mcp.delete.action")}
                    </button>
                  </div>
                </section>

                <section className="mcp-detail-section">
                  <header>
                    <div>
                      <h3>{t("mcp.detail.runtime")}</h3>
                      <p>{t(`mcp.alignment.${management.runtimeAlignment}`)}</p>
                    </div>
                    <button
                      className="secondary-button focus-ring"
                      disabled={refreshLocked}
                      onClick={() => void refreshCatalog()}
                    >
                      <Icon name="refresh" />
                      {t("mcp.refresh.action")}
                    </button>
                  </header>
                  <p className="mcp-existing-task-note">
                    {t("mcp.existing_tasks_note")}
                  </p>
                </section>

                <section className="mcp-tool-catalog">
                  <header>
                    <div>
                      <h3>{t("mcp.detail.tool_catalog")}</h3>
                      <p>{t("mcp.detail.tool_help")}</p>
                    </div>
                    <span>{selected.tools.length}</span>
                  </header>
                  {selected.tools.length === 0 ? (
                    <p className="mcp-no-tools">{t("mcp.detail.no_tools")}</p>
                  ) : (
                    <ul>
                      {selected.tools.map((tool) => (
                        <li key={tool.name}>
                          <div>
                            <code>{tool.name}</code>
                            <p>
                              {!tool.discovered
                                ? t("mcp.tool.not_discovered")
                                : tool.availableToNewTasks
                                  ? t("mcp.tool.available_to_new_tasks")
                                  : tool.desiredAllowed
                                    ? t("mcp.tool.allowed_not_available")
                                    : t("mcp.tool.not_allowed")}
                            </p>
                          </div>
                          <label className="mcp-tool-toggle">
                            <span className="sr-only">
                              {t("mcp.tool.toggle", { name: tool.name })}
                            </span>
                            <input
                              type="checkbox"
                              checked={tool.desiredAllowed}
                              disabled={
                                mutationLocked ||
                                pendingServerId === selected.id
                              }
                              onChange={() => {
                                const names = selected.tools
                                  .filter((candidate) =>
                                    candidate.name === tool.name
                                      ? !tool.desiredAllowed
                                      : candidate.desiredAllowed,
                                  )
                                  .map((candidate) => candidate.name);
                                void mutateServer(selected, (generation) =>
                                  onSetAllowedTools(
                                    generation,
                                    selected.id,
                                    names,
                                  ),
                                );
                              }}
                            />
                            <span aria-hidden="true" />
                          </label>
                        </li>
                      ))}
                    </ul>
                  )}
                </section>

                {confirmAction && (
                  <div
                    ref={confirmPanel}
                    className="mcp-confirm-panel"
                    role="alertdialog"
                    aria-labelledby="mcp-confirm-title"
                    aria-describedby="mcp-confirm-body"
                  >
                    <h3
                      id="mcp-confirm-title"
                      ref={confirmHeading}
                      tabIndex={-1}
                    >
                      {t(`mcp.confirm.${confirmAction}.title`)}
                    </h3>
                    <p id="mcp-confirm-body">
                      {t(`mcp.confirm.${confirmAction}.body`)}
                    </p>
                    <div>
                      <button
                        className="secondary-button focus-ring"
                        onClick={closeConfirmation}
                      >
                        {t("common.cancel")}
                      </button>
                      <button
                        className={
                          confirmAction === "delete"
                            ? "danger-button focus-ring"
                            : "primary-button focus-ring"
                        }
                        onClick={() => {
                          const action = confirmAction;
                          acceptConfirmation();
                          void mutateServer(selected, (generation) =>
                            action === "delete"
                              ? onRemove(generation, selected.id)
                              : onSetEnabled(
                                  generation,
                                  selected.id,
                                  action === "enable",
                                ),
                          ).then((result) => {
                            if (
                              action === "delete" &&
                              (result?.outcome === "saved" ||
                                result?.outcome === "saved_recovery_required")
                            )
                              closeDrawer();
                          });
                        }}
                      >
                        {t(`mcp.confirm.${confirmAction}.action`)}
                      </button>
                    </div>
                  </div>
                )}
              </div>
            ) : null}
          </aside>
        </div>
      )}
    </section>
  );
}
