import { useEffect, useId, useMemo, useRef, useState } from "react";

import type {
  McpManagementView,
  McpAuthorizationCancelResult,
  McpAuthorizationResult,
  McpConnectionTestResult,
  McpHttpConnectionInput,
  McpMutationResult,
  McpRefreshResult,
  McpSecretSlot,
  McpStdioConnectionInput,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Alert } from "../../components/ui/alert.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
import { Checkbox } from "../../components/ui/checkbox.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SearchField } from "../../components/ui/search-field.tsx";
import { SelectField } from "../../components/ui/select.tsx";
import { useI18n } from "../../i18n/context.ts";

type McpServer = McpManagementView["servers"][number];
type DrawerState =
  | { kind: "add" }
  | { kind: "replace"; id: string }
  | { kind: "server"; id: string }
  | null;
type ConfirmAction = "enable" | "disable" | "delete" | "allow_all" | null;

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

function validRawAuthorityPort(value: string): boolean {
  if (!/^:[0-9]+$/.test(value)) return false;
  const port = Number(value.slice(1));
  return Number.isInteger(port) && port > 0 && port <= 65535;
}

function validRawHostName(value: string): boolean {
  const host = value.endsWith(".") ? value.slice(0, -1) : value;
  if (host.length === 0 || host.length > 255) return false;
  return host
    .split(".")
    .every(
      (label) =>
        label.length > 0 &&
        label.length <= 63 &&
        /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label),
    );
}

function rawAuthorityHost(authority: string): string | null {
  if (
    authority.length === 0 ||
    authority.includes("@") ||
    authority.includes("%") ||
    /[^\x00-\x7f]/.test(authority)
  )
    return null;

  let host: string;
  let port = "";
  if (authority.startsWith("[")) {
    const closingBracket = authority.indexOf("]");
    if (closingBracket < 0) return null;
    host = authority.slice(0, closingBracket + 1);
    port = authority.slice(closingBracket + 1);
  } else {
    const separator = authority.indexOf(":");
    if (separator < 0) {
      host = authority;
    } else {
      if (authority.indexOf(":", separator + 1) >= 0) return null;
      host = authority.slice(0, separator);
      port = authority.slice(separator);
    }
  }

  if (
    !host ||
    (port && !validRawAuthorityPort(port)) ||
    (!host.startsWith("[") && !validRawHostName(host))
  )
    return null;
  return host;
}

export function validMcpHttpEndpoint(value: string): boolean {
  if (
    !/^https?:\/\//i.test(value) ||
    /[\u0000-\u0020\u007f\\?#]/.test(value) ||
    new TextEncoder().encode(value).length > 4096
  )
    return false;
  const authority = value.slice(value.indexOf("://") + 3).split("/", 1)[0];
  const host = rawAuthorityHost(authority);
  if (host === null) return false;
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
      ["localhost", "127.0.0.1", "[::1]"].includes(host.toLowerCase())
    );
  } catch {
    return false;
  }
}

function validMcpDisplayName(value: string): boolean {
  const trimmed = value.trim();
  return (
    trimmed.length > 0 &&
    !/[\u0000-\u001f\u007f]/.test(trimmed) &&
    new TextEncoder().encode(trimmed).length <= 256
  );
}

function validMcpPublicText(value: string, required = true): boolean {
  return (
    (!required || value.trim().length > 0) &&
    !/[\u0000-\u001f\u007f]/.test(value) &&
    new TextEncoder().encode(value).length <= 4096
  );
}

function validMcpNames(values: string[]): boolean {
  const normalized = values.map((value) => value.trim().toLocaleLowerCase());
  return (
    normalized.every((value) => validMcpPublicText(value)) &&
    new Set(normalized).size === normalized.length
  );
}

function serverNeedsAttention(server: McpServer) {
  return (
    server.approvalStatus === "unapproved" ||
    !["not_required", "ready"].includes(server.authorizationStatus) ||
    attentionStatuses.has(server.runtimeStatus) ||
    server.newTaskAccess === "restart_required" ||
    server.newTaskAccess === "unavailable"
  );
}

function serverStateKey(server: McpServer) {
  if (server.approvalStatus === "unapproved")
    return "mcp.approval.required" as const;
  if (!["not_required", "ready"].includes(server.authorizationStatus))
    return `mcp.authorization_status.${server.authorizationStatus}` as const;
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
          {t(`mcp.transport.${server.transport}`)} ·{" "}
          {t(`mcp.auth.${server.authMode}`)}
        </span>
        <span className="mcp-server-tools">
          {t("mcp.tool_access_summary", {
            available,
            total: server.tools.length,
          })}
        </span>
        <span className="mcp-server-state">
          <span
            className="mcp-state-dot"
            data-state={
              server.connectionTest.status !== "untested"
                ? server.connectionTest.status
                : server.newTaskAccess
            }
            aria-hidden="true"
          />
          {server.connectionTest.status === "connected"
            ? t("mcp.pipeline.test_connected", {
                tools: server.connectionTest.toolCount,
              })
            : server.connectionTest.status === "failed"
              ? t("mcp.pipeline.test_failed", {
                  issues: server.connectionTest.issueCount,
                })
              : t(serverStateKey(server))}
        </span>
        <Icon name="chevron-right" />
      </button>
    </li>
  );
}

function McpTextRows({
  label,
  addLabel,
  values,
  onChange,
}: {
  label: string;
  addLabel: string;
  values: string[];
  onChange: (values: string[]) => void;
}) {
  const { t } = useI18n();
  const labelId = useId();
  return (
    <div className="mcp-text-rows" role="group" aria-labelledby={labelId}>
      <span className="mcp-field-label" id={labelId}>
        {label}
      </span>
      {values.map((value, index) => (
        <div key={index}>
          <Input
            aria-label={`${label} ${index + 1}`}
            value={value}
            onChange={(event) =>
              onChange(
                values.map((candidate, candidateIndex) =>
                  candidateIndex === index ? event.target.value : candidate,
                ),
              )
            }
          />
          <button
            type="button"
            className="icon-button focus-ring"
            aria-label={t("mcp.add.remove_row")}
            onClick={() =>
              onChange(
                values.filter((_, candidateIndex) => candidateIndex !== index),
              )
            }
          >
            <Icon name="trash" />
          </button>
        </div>
      ))}
      <button
        type="button"
        className="mcp-add-row focus-ring"
        onClick={() => onChange([...values, ""])}
      >
        <Icon name="plus" /> {addLabel}
      </button>
    </div>
  );
}

function McpCodeValues({ values, empty }: { values: string[]; empty: string }) {
  if (values.length === 0) return <span>{empty}</span>;
  return (
    <ul className="mcp-config-values">
      {values.map((value, index) => (
        <li key={`${index}:${value}`}>
          <code>{value}</code>
        </li>
      ))}
    </ul>
  );
}

export function McpPage({
  management,
  query,
  disabled,
  onQuery,
  capabilities,
  onCreateStdio,
  onCreateHttp,
  onUpdateStdio,
  onUpdateHttp,
  onRename,
  onApprove,
  onCaptureSecret,
  onAuthorize,
  onCancelAuthorization,
  onSetEnabled,
  onSetAllowedTools,
  onRemove,
  onTest,
  onRefresh,
}: {
  management: McpManagementView;
  capabilities: {
    connectionApproval: boolean;
    secretCapture: boolean;
    oauth: boolean;
  };
  query: string;
  disabled: boolean;
  onQuery: (query: string) => void;
  onCreateStdio: (
    expectedGeneration: string,
    input: McpStdioConnectionInput,
  ) => Promise<McpMutationResult>;
  onCreateHttp: (
    expectedGeneration: string,
    input: McpHttpConnectionInput,
  ) => Promise<McpMutationResult>;
  onUpdateStdio: (
    expectedGeneration: string,
    serverId: string,
    input: McpStdioConnectionInput,
  ) => Promise<McpMutationResult>;
  onUpdateHttp: (
    expectedGeneration: string,
    serverId: string,
    input: McpHttpConnectionInput,
  ) => Promise<McpMutationResult>;
  onRename: (
    expectedGeneration: string,
    serverId: string,
    displayName: string,
  ) => Promise<McpMutationResult>;
  onApprove: (
    expectedGeneration: string,
    serverId: string,
  ) => Promise<McpMutationResult>;
  onCaptureSecret: (
    expectedGeneration: string,
    serverId: string,
    slot: McpSecretSlot,
  ) => Promise<McpMutationResult>;
  onAuthorize: (
    expectedGeneration: string,
    serverId: string,
  ) => Promise<McpAuthorizationResult>;
  onCancelAuthorization: (
    operationId: string,
  ) => Promise<McpAuthorizationCancelResult>;
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
  onTest: (
    expectedGeneration: string,
    serverId: string,
  ) => Promise<McpConnectionTestResult>;
  onRefresh: () => Promise<McpRefreshResult>;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const drawer = useRef<HTMLDivElement>(null);
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
  const [cancelPending, setCancelPending] = useState(false);
  const [displayName, setDisplayName] = useState("");
  const [transport, setTransport] = useState<"stdio" | "streamable_http">(
    "stdio",
  );
  const [negotiation, setNegotiation] = useState<
    "automatic" | "modern_only" | "compat_only"
  >("automatic");
  const [timeoutMs, setTimeoutMs] = useState("30000");
  const [command, setCommand] = useState("");
  const [argumentsDraft, setArgumentsDraft] = useState<string[]>([]);
  const [cwd, setCwd] = useState("");
  const [environmentNames, setEnvironmentNames] = useState<string[]>([]);
  const [endpoint, setEndpoint] = useState("");
  const [authMode, setAuthMode] = useState<"none" | "static" | "oauth">("none");
  const [headerNames, setHeaderNames] = useState<string[]>([]);
  const [registrationKind, setRegistrationKind] = useState<
    "automatic" | "pre_registered"
  >("automatic");
  const [clientId, setClientId] = useState("");
  const [tokenEndpointAuthMethod, setTokenEndpointAuthMethod] = useState<
    "none" | "client_secret_basic" | "client_secret_post"
  >("none");
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
    drawerState && drawerState.kind !== "add"
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
    pendingServerId !== null ||
    management.authorizationOperation.kind !== "idle";
  const selectedOperationBusy =
    selected !== null &&
    ((management.authorizationOperation.kind !== "idle" &&
      management.authorizationOperation.serverId === selected.id) ||
      selected.connectionTest.status === "testing");
  const addValid =
    validMcpDisplayName(displayName) &&
    /^(?:[1-9][0-9]{0,8})$/.test(timeoutMs) &&
    (transport === "stdio"
      ? validMcpPublicText(command.trim()) &&
        argumentsDraft.every((value) => validMcpPublicText(value, false)) &&
        validMcpPublicText(cwd, false) &&
        validMcpNames(environmentNames)
      : validMcpHttpEndpoint(endpoint.trim()) &&
        validMcpNames(headerNames) &&
        ((authMode === "none" && headerNames.length === 0) ||
          (authMode === "static" && headerNames.length > 0) ||
          (authMode === "oauth" &&
            headerNames.length === 0 &&
            (registrationKind === "automatic" ||
              validMcpPublicText(clientId.trim())))));

  useEffect(() => title.current?.focus(), []);

  useEffect(() => {
    if (!drawerState) return;
    const frame = window.requestAnimationFrame(() =>
      drawerHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [drawerState?.kind, selected?.id]);

  useEffect(() => {
    if (drawerState && drawerState.kind !== "add" && !selected)
      setDrawerState(null);
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
    setTransport("stdio");
    setNegotiation("automatic");
    setTimeoutMs("30000");
    setCommand("");
    setArgumentsDraft([]);
    setCwd("");
    setEnvironmentNames([]);
    setEndpoint("");
    setAuthMode("none");
    setHeaderNames([]);
    setRegistrationKind("automatic");
    setClientId("");
    setTokenEndpointAuthMethod("none");
    setNotice(null);
    setDrawerState({ kind: "add" });
  }

  function openReplacement(server: McpServer) {
    const connection = server.connection;
    if (connection === null) return;
    setDisplayName(server.displayName);
    setTransport(server.transport);
    setNegotiation(server.negotiation);
    setTimeoutMs(String(server.timeoutMs));
    setCommand(connection.kind === "stdio" ? connection.command : "");
    setArgumentsDraft(
      connection.kind === "stdio" ? [...connection.arguments] : [],
    );
    setCwd(connection.kind === "stdio" ? (connection.cwd ?? "") : "");
    setEnvironmentNames(
      connection.kind === "stdio"
        ? connection.environment.map((slot) => slot.name)
        : [],
    );
    setEndpoint(
      connection.kind === "streamable_http" ? connection.endpoint : "",
    );
    setAuthMode(server.authMode);
    setHeaderNames(
      connection.kind === "streamable_http"
        ? connection.headers.map((slot) => slot.name)
        : [],
    );
    setRegistrationKind(
      connection.kind === "streamable_http" &&
        connection.registrationKind === "pre_registered"
        ? "pre_registered"
        : "automatic",
    );
    setClientId(
      connection.kind === "streamable_http" && connection.clientId !== null
        ? connection.clientId
        : "",
    );
    setTokenEndpointAuthMethod(
      connection.kind === "streamable_http" &&
        connection.tokenEndpointAuthMethod !== null
        ? connection.tokenEndpointAuthMethod
        : "none",
    );
    setNotice(null);
    setDrawerState({ kind: "replace", id: server.id });
  }

  const autoTest = useRef<{ id: string } | { ids: Set<string> } | null>(null);
  const authorizationSection = useRef<HTMLElement>(null);

  useEffect(() => {
    // Needs-authentication servers land the user on the credential section
    // instead of asking them to hunt through the drawer.
    if (
      drawerState?.kind === "server" &&
      selected?.runtimeStatus === "needs_authentication"
    )
      authorizationSection.current?.scrollIntoView({ block: "start" });
  }, [drawerState?.kind, selected?.id, selected?.runtimeStatus]);

  useEffect(() => {
    // Save-and-test: once the saved server is visible in the refreshed
    // projection, land its detail view and start the side-effect-free test.
    const pending = autoTest.current;
    if (!pending || !management.desiredGeneration) return;
    const server =
      "id" in pending
        ? management.servers.find((entry) => entry.id === pending.id)
        : management.servers.find((entry) => !pending.ids.has(entry.id));
    if (!server) return;
    autoTest.current = null;
    setDrawerState({ kind: "server", id: server.id });
    void testConnection(server);
  });

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
      "busy",
      "capability_unavailable",
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
      const shared = {
        displayName: displayName.trim(),
        negotiation,
        timeoutMs: Number(timeoutMs),
      };
      const input =
        transport === "stdio"
          ? ({
              ...shared,
              command: command.trim(),
              arguments: argumentsDraft,
              cwd: cwd.trim() || null,
              environmentNames: environmentNames.map((value) => value.trim()),
            } satisfies McpStdioConnectionInput)
          : ({
              ...shared,
              endpoint: endpoint.trim(),
              authMode,
              headerNames: headerNames.map((value) => value.trim()),
              registration:
                authMode !== "oauth"
                  ? null
                  : registrationKind === "automatic"
                    ? { kind: "automatic" }
                    : {
                        kind: "pre_registered",
                        clientId: clientId.trim(),
                        tokenEndpointAuthMethod,
                      },
            } satisfies McpHttpConnectionInput);
      const result =
        drawerState?.kind === "replace" && selected
          ? transport === "stdio"
            ? await onUpdateStdio(
                generation,
                selected.id,
                input as McpStdioConnectionInput,
              )
            : await onUpdateHttp(
                generation,
                selected.id,
                input as McpHttpConnectionInput,
              )
          : transport === "stdio"
            ? await onCreateStdio(generation, input as McpStdioConnectionInput)
            : await onCreateHttp(generation, input as McpHttpConnectionInput);
      mutationNotice(result);
      if (result.outcome === "saved") {
        autoTest.current =
          drawerState?.kind === "replace" && selected
            ? { id: selected.id }
            : { ids: new Set(management.servers.map((server) => server.id)) };
      } else if (result.outcome === "saved_recovery_required") closeDrawer();
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

  async function authorizeServer(server: McpServer) {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || pendingServerId === server.id) return;
    setPendingServerId(server.id);
    try {
      const result = await onAuthorize(generation, server.id);
      setNotice({
        tone: result.outcome === "started" ? "quiet" : "attention",
        text: t(`mcp.authorization.${result.outcome}`),
      });
    } catch {
      setNotice({ tone: "attention", text: t("mcp.mutation.failed") });
    } finally {
      setPendingServerId(null);
    }
  }

  async function testConnection(server: McpServer) {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || pendingServerId === server.id) return;
    setPendingServerId(server.id);
    setNotice(null);
    try {
      const result = await onTest(generation, server.id);
      setNotice({
        tone: result.outcome === "started" ? "quiet" : "attention",
        text: t(`mcp.test.${result.outcome}`),
      });
    } catch {
      setNotice({ tone: "attention", text: t("mcp.test.failed") });
    } finally {
      setPendingServerId(null);
    }
  }

  async function cancelAuthorization() {
    const operation = management.authorizationOperation;
    if (operation.kind === "idle" || cancelPending) return;
    setCancelPending(true);
    try {
      const result = await onCancelAuthorization(operation.operationId);
      setNotice({
        tone: result.outcome === "cancelled" ? "quiet" : "attention",
        text: t(`mcp.cancel.${result.outcome}`),
      });
    } catch {
      setNotice({ tone: "attention", text: t("mcp.mutation.failed") });
    } finally {
      setCancelPending(false);
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
        <Alert variant="danger" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.outcome_unknown.title")}</strong>
            <p>{t("mcp.banner.outcome_unknown.body")}</p>
          </div>
        </Alert>
      );
    if (management.managementHealth === "recovery_required")
      return (
        <Alert variant="warning" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.recovery.title")}</strong>
            <p>{t("mcp.banner.recovery.body")}</p>
          </div>
        </Alert>
      );
    if (management.runtimeAlignment === "restart_required")
      return (
        <Alert variant="warning" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.restart.title")}</strong>
            <p>{t("mcp.banner.restart.body")}</p>
          </div>
        </Alert>
      );
    if (management.runtimeAlignment === "unknown" && managementReady)
      return (
        <Alert variant="warning" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.alignment_unknown.title")}</strong>
            <p>{t("mcp.banner.alignment_unknown.body")}</p>
          </div>
        </Alert>
      );
    if (management.availability === "unavailable" && managementReady)
      return (
        <Alert variant="neutral" className="mcp-state-banner">
          <Icon name="mcp" />
          <div>
            <strong>{t("mcp.banner.runtime_unavailable.title")}</strong>
            <p>{t("mcp.banner.runtime_unavailable.body")}</p>
          </div>
        </Alert>
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
            {!empty && (
              <Button
                variant="primary"
                size="sm"
                disabled={mutationLocked}
                onClick={(event) => openAdd(event.currentTarget)}
              >
                <Icon name="plus" />
                {t("mcp.add.action")}
              </Button>
            )}
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

        {!unavailable && !frozenWithoutDesired && !empty && (
          <div className="mcp-toolbar">
            <SearchField
              className="w-[min(100%,420px)]"
              label={t("mcp.search_label")}
              value={query}
              placeholder={t("mcp.search_placeholder")}
              onChange={(event) => onQuery(event.target.value)}
            />
            <Button
              variant="secondary"
              size="sm"
              disabled={refreshLocked}
              onClick={() => void refreshCatalog()}
            >
              <Icon name="refresh" />
              {refreshPending || management.operation === "refreshing"
                ? t("mcp.refresh.refreshing")
                : t("mcp.refresh.action")}
            </Button>
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
            <Button
              variant="primary"
              size="sm"
              disabled={mutationLocked}
              onClick={(event) => openAdd(event.currentTarget)}
            >
              <Icon name="plus" />
              {t("mcp.add.action")}
            </Button>
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

      <Drawer.Root
        open={drawerState !== null}
        onOpenChange={(open) => {
          if (!open) closeDrawer();
        }}
      >
        <Drawer.Portal>
          <Drawer.Backdrop className="mcp-drawer-backdrop" />
          <Drawer.Popup
            ref={drawer}
            className="mcp-drawer w-[min(620px,calc(100vw-28px))] max-[620px]:w-full max-[620px]:border-l-0 bg-(--ui-surface-canvas) shadow-[-18px_0_54px_rgba(37,34,45,0.13)]"
            aria-labelledby="mcp-drawer-title"
          >
            <header>
              <div>
                <small>
                  {drawerState?.kind === "add"
                    ? t("mcp.add.eyebrow")
                    : drawerState?.kind === "replace"
                      ? t("mcp.edit.eyebrow")
                      : t("mcp.detail.eyebrow")}
                </small>
                <h2 id="mcp-drawer-title" ref={drawerHeading} tabIndex={-1}>
                  {drawerState?.kind === "add"
                    ? t("mcp.add.title")
                    : drawerState?.kind === "replace"
                      ? t("mcp.edit.title")
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

            {drawerState?.kind === "add" || drawerState?.kind === "replace" ? (
              <form
                className="mcp-add-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  void createServer();
                }}
              >
                <div className="mcp-add-fields">
                  <p className="mcp-form-intro">
                    {t(
                      drawerState?.kind === "replace"
                        ? "mcp.edit.intro"
                        : "mcp.add.intro",
                    )}
                  </p>
                  <fieldset className="mcp-transport-choice">
                    <legend>{t("mcp.add.transport")}</legend>
                    <button
                      type="button"
                      data-selected={transport === "stdio"}
                      disabled={drawerState?.kind === "replace"}
                      onClick={() => setTransport("stdio")}
                    >
                      <Icon name="mcp" />
                      <span>
                        <strong>STDIO</strong>
                        <small>{t("mcp.add.stdio_help")}</small>
                      </span>
                    </button>
                    <button
                      type="button"
                      data-selected={transport === "streamable_http"}
                      disabled={drawerState?.kind === "replace"}
                      onClick={() => setTransport("streamable_http")}
                    >
                      <Icon name="mcp" />
                      <span>
                        <strong>Streamable HTTP</strong>
                        <small>{t("mcp.add.http_help")}</small>
                      </span>
                    </button>
                  </fieldset>
                  <label>
                    <span>{t("mcp.add.name")}</span>
                    <Input
                      autoComplete="off"
                      value={displayName}
                      maxLength={256}
                      disabled={createPending}
                      onChange={(event) => setDisplayName(event.target.value)}
                    />
                  </label>
                  <div className="mcp-form-pair">
                    <label>
                      <span>{t("mcp.add.protocol")}</span>
                      <SelectField
                        value={negotiation}
                        onValueChange={(value) =>
                          setNegotiation(value as typeof negotiation)
                        }
                        options={[
                          { value: "automatic", label: "Automatic" },
                          { value: "modern_only", label: "2026-07-28" },
                          { value: "compat_only", label: "2025-11-25" },
                        ]}
                        aria-label={t("mcp.add.protocol")}
                      />
                    </label>
                    <label>
                      <span>{t("mcp.add.timeout")}</span>
                      <Input
                        inputMode="numeric"
                        value={timeoutMs}
                        onChange={(event) => setTimeoutMs(event.target.value)}
                      />
                    </label>
                  </div>
                  {transport === "stdio" ? (
                    <>
                      <label>
                        <span>{t("mcp.add.command")}</span>
                        <Input
                          autoComplete="off"
                          value={command}
                          placeholder="npx"
                          onChange={(event) => setCommand(event.target.value)}
                        />
                      </label>
                      <McpTextRows
                        label={t("mcp.add.arguments")}
                        addLabel={t("mcp.add.argument")}
                        values={argumentsDraft}
                        onChange={setArgumentsDraft}
                      />
                      <label>
                        <span>{t("mcp.add.cwd")}</span>
                        <Input
                          autoComplete="off"
                          value={cwd}
                          onChange={(event) => setCwd(event.target.value)}
                        />
                      </label>
                      <McpTextRows
                        label={t("mcp.add.environment")}
                        addLabel={t("mcp.add.environment_name")}
                        values={environmentNames}
                        onChange={setEnvironmentNames}
                      />
                    </>
                  ) : (
                    <>
                      <label>
                        <span id="mcp-add-endpoint-label">
                          {t("mcp.add.endpoint")}
                        </span>
                        <Input
                          autoComplete="off"
                          inputMode="url"
                          placeholder="https://mcp.example.com"
                          value={endpoint}
                          maxLength={4096}
                          disabled={createPending}
                          aria-labelledby="mcp-add-endpoint-label"
                          aria-describedby="mcp-add-endpoint-help"
                          aria-invalid={
                            endpoint.length > 0 &&
                            !validMcpHttpEndpoint(endpoint)
                          }
                          onChange={(event) => setEndpoint(event.target.value)}
                        />
                        <small id="mcp-add-endpoint-help">
                          {t("mcp.add.endpoint_help")}
                        </small>
                      </label>
                      <fieldset className="mcp-auth-choice">
                        <legend>{t("mcp.add.authentication")}</legend>
                        {(["none", "static", "oauth"] as const).map((mode) => (
                          <label key={mode}>
                            <Input
                              type="radio"
                              name="mcp-auth-mode"
                              checked={authMode === mode}
                              disabled={
                                (mode === "oauth" && !capabilities.oauth) ||
                                (mode === "static" &&
                                  !capabilities.secretCapture &&
                                  !(
                                    drawerState?.kind === "replace" &&
                                    selected?.authMode === "static"
                                  ))
                              }
                              onChange={() => {
                                setAuthMode(mode);
                                if (mode !== "static") setHeaderNames([]);
                              }}
                            />
                            <span>
                              {t(`mcp.auth.${mode}`)}
                              {mode === "static" &&
                                !capabilities.secretCapture &&
                                !(
                                  drawerState?.kind === "replace" &&
                                  selected?.authMode === "static"
                                ) && (
                                  <small>{t("mcp.auth.static_locked")}</small>
                                )}
                            </span>
                          </label>
                        ))}
                      </fieldset>
                      {authMode === "static" && (
                        <McpTextRows
                          label={t("mcp.add.headers")}
                          addLabel={t("mcp.add.header_name")}
                          values={headerNames}
                          onChange={setHeaderNames}
                        />
                      )}
                      {authMode === "oauth" && (
                        <div className="mcp-oauth-fields">
                          <label>
                            <span>{t("mcp.add.registration")}</span>
                            <SelectField
                              value={registrationKind}
                              onValueChange={(value) =>
                                setRegistrationKind(
                                  value as typeof registrationKind,
                                )
                              }
                              options={[
                                {
                                  value: "automatic",
                                  label: t("mcp.add.registration.automatic"),
                                },
                                {
                                  value: "pre_registered",
                                  label: t("mcp.add.registration.existing"),
                                },
                              ]}
                              aria-label={t("mcp.add.registration")}
                            />
                          </label>
                          {registrationKind === "pre_registered" && (
                            <>
                              <label>
                                <span>{t("mcp.add.client_id")}</span>
                                <Input
                                  autoComplete="off"
                                  value={clientId}
                                  onChange={(event) =>
                                    setClientId(event.target.value)
                                  }
                                />
                              </label>
                              <label>
                                <span>{t("mcp.add.client_auth_method")}</span>
                                <SelectField
                                  value={tokenEndpointAuthMethod}
                                  onValueChange={(value) =>
                                    setTokenEndpointAuthMethod(
                                      value as typeof tokenEndpointAuthMethod,
                                    )
                                  }
                                  options={[
                                    {
                                      value: "none",
                                      label: t("mcp.client_auth.none"),
                                    },
                                    {
                                      value: "client_secret_basic",
                                      label: t(
                                        "mcp.client_auth.client_secret_basic",
                                      ),
                                    },
                                    {
                                      value: "client_secret_post",
                                      label: t(
                                        "mcp.client_auth.client_secret_post",
                                      ),
                                    },
                                  ]}
                                  aria-label={t("mcp.add.client_auth_method")}
                                />
                              </label>
                            </>
                          )}
                        </div>
                      )}
                    </>
                  )}
                  <div className="mcp-add-defaults">
                    <Icon name="check" />
                    <p>{t("mcp.add.defaults")}</p>
                  </div>
                </div>
                <footer>
                  <Button
                    type="button"
                    variant="secondary"
                    size="sm"
                    onClick={closeDrawer}
                  >
                    {t("common.cancel")}
                  </Button>
                  <Button
                    type="submit"
                    variant="primary"
                    size="sm"
                    disabled={!addValid || mutationLocked || createPending}
                  >
                    {createPending
                      ? t("mcp.add.adding")
                      : drawerState?.kind === "replace"
                        ? t("mcp.edit.submit")
                        : t("mcp.add.submit")}
                  </Button>
                </footer>
              </form>
            ) : selected ? (
              <div className="mcp-detail-body">
                <ol
                  className="mcp-pipeline"
                  aria-label={t("mcp.pipeline.label")}
                >
                  <li data-state={selected.connectionTest.status}>
                    {selected.connectionTest.status === "connected"
                      ? t("mcp.pipeline.test_connected", {
                          tools: selected.connectionTest.toolCount,
                        })
                      : selected.connectionTest.status === "failed"
                        ? t("mcp.pipeline.test_failed", {
                            issues: selected.connectionTest.issueCount,
                          })
                        : t("mcp.pipeline.test_pending")}
                  </li>
                  <li
                    data-state={
                      selected.tools.some((tool) => tool.desiredAllowed)
                        ? "connected"
                        : "untested"
                    }
                  >
                    {t("mcp.pipeline.tools", {
                      allowed: selected.tools.filter(
                        (tool) => tool.desiredAllowed,
                      ).length,
                      total: selected.tools.length,
                    })}
                  </li>
                  <li
                    data-state={
                      selected.newTaskAccess === "available"
                        ? "connected"
                        : "untested"
                    }
                  >
                    {selected.newTaskAccess === "restart_required"
                      ? t("mcp.pipeline.restart_hint")
                      : t(`mcp.access.${selected.newTaskAccess}`)}
                  </li>
                </ol>
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
                      <Input
                        value={renameDraft}
                        maxLength={256}
                        disabled={
                          mutationLocked ||
                          pendingServerId === selected.id ||
                          selectedOperationBusy
                        }
                        onChange={(event) => setRenameDraft(event.target.value)}
                      />
                    </label>
                    <Button
                      type="submit"
                      variant="secondary"
                      size="sm"
                      disabled={
                        mutationLocked ||
                        pendingServerId === selected.id ||
                        selectedOperationBusy ||
                        !validMcpDisplayName(renameDraft) ||
                        renameDraft.trim() === selected.displayName
                      }
                    >
                      {t("mcp.rename.action")}
                    </Button>
                  </form>
                  <dl className="mcp-connection-summary">
                    <div>
                      <dt>{t("mcp.detail.protocol")}</dt>
                      <dd>{t(`mcp.negotiation.${selected.negotiation}`)}</dd>
                    </div>
                    <div>
                      <dt>{t("mcp.add.timeout")}</dt>
                      <dd>{selected.timeoutMs}</dd>
                    </div>
                    <div>
                      <dt>{t("mcp.detail.authentication")}</dt>
                      <dd>{t(`mcp.auth.${selected.authMode}`)}</dd>
                    </div>
                    {selected.connection?.kind === "stdio" ? (
                      <>
                        <div>
                          <dt>{t("mcp.detail.executable")}</dt>
                          <dd>
                            <code>{selected.connection.command}</code>
                          </dd>
                        </div>
                        <div>
                          <dt>{t("mcp.detail.arguments")}</dt>
                          <dd>
                            <McpCodeValues
                              values={selected.connection.arguments}
                              empty={t("mcp.summary.not_configured")}
                            />
                          </dd>
                        </div>
                        <div>
                          <dt>{t("mcp.detail.cwd")}</dt>
                          <dd>
                            {selected.connection.cwd === null ? (
                              t("mcp.summary.not_configured")
                            ) : (
                              <code>{selected.connection.cwd}</code>
                            )}
                          </dd>
                        </div>
                        <div>
                          <dt>{t("mcp.detail.environment_names")}</dt>
                          <dd>
                            <McpCodeValues
                              values={selected.connection.environment.map(
                                (slot) => slot.name,
                              )}
                              empty={t("mcp.summary.not_configured")}
                            />
                          </dd>
                        </div>
                      </>
                    ) : selected.connection?.kind === "streamable_http" ? (
                      <>
                        <div>
                          <dt>{t("mcp.add.endpoint")}</dt>
                          <dd>
                            <code>{selected.connection.endpoint}</code>
                          </dd>
                        </div>
                        <div>
                          <dt>{t("mcp.detail.header_names")}</dt>
                          <dd>
                            <McpCodeValues
                              values={selected.connection.headers.map(
                                (slot) => slot.name,
                              )}
                              empty={t("mcp.summary.not_configured")}
                            />
                          </dd>
                        </div>
                        {selected.authMode === "oauth" && (
                          <>
                            <div>
                              <dt>{t("mcp.detail.registration")}</dt>
                              <dd>
                                {t(
                                  `mcp.registration.${selected.connection.registrationKind}`,
                                )}
                              </dd>
                            </div>
                            {selected.connection.clientId !== null && (
                              <div>
                                <dt>{t("mcp.add.client_id")}</dt>
                                <dd>
                                  <code>{selected.connection.clientId}</code>
                                </dd>
                              </div>
                            )}
                            {selected.connection.tokenEndpointAuthMethod !==
                              null && (
                              <div>
                                <dt>{t("mcp.add.client_auth_method")}</dt>
                                <dd>
                                  {t(
                                    `mcp.client_auth.${selected.connection.tokenEndpointAuthMethod}`,
                                  )}
                                </dd>
                              </div>
                            )}
                          </>
                        )}
                      </>
                    ) : (
                      <div className="mcp-configuration-unavailable">
                        <dt>{t("mcp.detail.connection_unavailable")}</dt>
                        <dd>{t("mcp.detail.connection_unavailable_help")}</dd>
                      </div>
                    )}
                  </dl>
                  {selected.approvalStatus === "unapproved" && (
                    <div className="mcp-attention-action">
                      <div>
                        <strong>{t("mcp.approval.required")}</strong>
                        <p>{t("mcp.approval.help")}</p>
                      </div>
                      {capabilities.connectionApproval ? (
                        <Button
                          variant="primary"
                          size="sm"
                          disabled={
                            mutationLocked ||
                            pendingServerId === selected.id ||
                            selectedOperationBusy
                          }
                          onClick={() =>
                            void mutateServer(selected, (generation) =>
                              onApprove(generation, selected.id),
                            )
                          }
                        >
                          {t("mcp.approval.action")}
                        </Button>
                      ) : (
                        <span>{t("mcp.capability.approval_unavailable")}</span>
                      )}
                    </div>
                  )}
                  <div className="mcp-configuration-actions">
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={
                        mutationLocked ||
                        pendingServerId === selected.id ||
                        selectedOperationBusy ||
                        selected.connection === null
                      }
                      onClick={() => openReplacement(selected)}
                    >
                      {t("mcp.edit.action")}
                    </Button>
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={
                        mutationLocked ||
                        pendingServerId === selected.id ||
                        selectedOperationBusy ||
                        (!selected.desiredEnabled &&
                          selected.approvalStatus !== "approved")
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
                    </Button>
                    <Button
                      variant="danger"
                      size="sm"
                      disabled={
                        mutationLocked ||
                        pendingServerId === selected.id ||
                        selectedOperationBusy
                      }
                      onClick={(event) =>
                        openConfirmation("delete", event.currentTarget)
                      }
                    >
                      <Icon name="trash" />
                      {t("mcp.delete.action")}
                    </Button>
                  </div>
                </section>

                <section
                  className="mcp-detail-section"
                  ref={authorizationSection}
                >
                  <header>
                    <div>
                      <h3>{t("mcp.detail.authorization")}</h3>
                      <p>
                        {t(
                          `mcp.authorization_status.${selected.authorizationStatus}`,
                        )}
                      </p>
                    </div>
                  </header>
                  {selected.authMode === "static" && (
                    <ul className="mcp-secret-slots">
                      {(selected.connection?.kind === "stdio"
                        ? selected.connection.environment
                        : selected.connection?.kind === "streamable_http"
                          ? selected.connection.headers
                          : []
                      ).map((slot) => (
                        <li key={slot.name}>
                          <code>{slot.name}</code>
                          <span>{t(`mcp.secret.${slot.status}`)}</span>
                          {capabilities.secretCapture ? (
                            <Button
                              variant="secondary"
                              size="sm"
                              disabled={
                                mutationLocked ||
                                pendingServerId === selected.id ||
                                selectedOperationBusy ||
                                selected.approvalStatus !== "approved"
                              }
                              onClick={() =>
                                void mutateServer(selected, (generation) =>
                                  onCaptureSecret(generation, selected.id, {
                                    kind:
                                      selected.transport === "stdio"
                                        ? "stdio_environment"
                                        : "http_header",
                                    name: slot.name,
                                  }),
                                )
                              }
                            >
                              {slot.status === "set"
                                ? t("mcp.secret.replace")
                                : t("mcp.secret.set")}
                            </Button>
                          ) : (
                            <span>
                              {t("mcp.capability.capture_unavailable")}
                            </span>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}
                  {selected.authMode === "oauth" && (
                    <div className="mcp-oauth-action">
                      {selected.connection?.kind === "streamable_http" &&
                        selected.connection.registrationKind ===
                          "pre_registered" &&
                        selected.connection.clientSecretStatus !==
                          "not_required" && (
                          <div className="mcp-client-secret-action">
                            <span>
                              {t(
                                `mcp.secret.${selected.connection.clientSecretStatus}`,
                              )}
                            </span>
                            {capabilities.secretCapture ? (
                              <Button
                                variant="secondary"
                                size="sm"
                                disabled={
                                  mutationLocked ||
                                  pendingServerId === selected.id ||
                                  selectedOperationBusy ||
                                  selected.approvalStatus !== "approved"
                                }
                                onClick={() =>
                                  void mutateServer(selected, (generation) =>
                                    onCaptureSecret(generation, selected.id, {
                                      kind: "oauth_client_secret",
                                    }),
                                  )
                                }
                              >
                                {selected.connection.clientSecretStatus ===
                                "set"
                                  ? t("mcp.secret.replace")
                                  : t("mcp.secret.set")}
                              </Button>
                            ) : (
                              <span>
                                {t("mcp.capability.capture_unavailable")}
                              </span>
                            )}
                          </div>
                        )}
                      {management.authorizationOperation.kind !== "idle" &&
                      management.authorizationOperation.serverId ===
                        selected.id ? (
                        <>
                          <span>
                            {t(
                              `mcp.authorization_phase.${management.authorizationOperation.kind}`,
                            )}
                          </span>
                          <Button
                            variant="secondary"
                            size="sm"
                            disabled={cancelPending}
                            onClick={() => void cancelAuthorization()}
                          >
                            {t("mcp.authorization.cancel")}
                          </Button>
                        </>
                      ) : management.authorizationOperation.kind !== "idle" ? (
                        <span>{t("mcp.authorization.busy")}</span>
                      ) : capabilities.oauth ? (
                        <Button
                          variant="primary"
                          size="sm"
                          disabled={
                            mutationLocked ||
                            selected.approvalStatus !== "approved" ||
                            management.authorizationOperation.kind !== "idle" ||
                            selected.authorizationStatus ===
                              "capability_unavailable" ||
                            (selected.connection?.kind === "streamable_http" &&
                              selected.connection.registrationKind ===
                                "pre_registered" &&
                              selected.connection.clientSecretStatus ===
                                "missing") ||
                            selected.authorizationStatus === "ready"
                          }
                          onClick={() => void authorizeServer(selected)}
                        >
                          {selected.authorizationStatus === "reauth_required"
                            ? t("mcp.authorization.again")
                            : t("mcp.authorization.action")}
                        </Button>
                      ) : (
                        <span>{t("mcp.capability.oauth_unavailable")}</span>
                      )}
                    </div>
                  )}
                </section>

                <section className="mcp-detail-section">
                  <header>
                    <div>
                      <h3>{t("mcp.detail.runtime")}</h3>
                      <p>{t(`mcp.alignment.${management.runtimeAlignment}`)}</p>
                    </div>
                    <Button
                      variant="primary"
                      size="sm"
                      disabled={
                        mutationLocked ||
                        pendingServerId === selected.id ||
                        selectedOperationBusy ||
                        !selected.desiredEnabled ||
                        selected.approvalStatus !== "approved"
                      }
                      onClick={() => void testConnection(selected)}
                    >
                      <Icon name="mcp" />
                      {selected.connectionTest.status === "testing"
                        ? t("mcp.test.testing")
                        : t("mcp.test.action")}
                    </Button>
                  </header>
                  {selected.connectionTest.status !== "untested" && (
                    <p
                      className="mcp-operation-notice"
                      data-tone={
                        selected.connectionTest.status === "connected"
                          ? "quiet"
                          : selected.connectionTest.status === "failed"
                            ? "attention"
                            : "quiet"
                      }
                      aria-live="polite"
                    >
                      {selected.connectionTest.status === "connected"
                        ? t("mcp.test.connected", {
                            tools: selected.connectionTest.toolCount,
                            issues: selected.connectionTest.issueCount,
                          })
                        : t(`mcp.test.${selected.connectionTest.status}`)}
                    </p>
                  )}
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
                    {selected.tools.some(
                      (tool) => tool.discovered && !tool.desiredAllowed,
                    ) && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={
                          mutationLocked ||
                          pendingServerId === selected.id ||
                          selectedOperationBusy
                        }
                        onClick={() => setConfirmAction("allow_all")}
                      >
                        {t("mcp.detail.allow_all", {
                          count: selected.tools.filter(
                            (tool) => tool.discovered && !tool.desiredAllowed,
                          ).length,
                        })}
                      </Button>
                    )}
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
                            <Checkbox.Root
                              checked={tool.desiredAllowed}
                              disabled={
                                mutationLocked ||
                                pendingServerId === selected.id ||
                                selectedOperationBusy
                              }
                              onCheckedChange={() => {
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
                            >
                              <Checkbox.Indicator>✓</Checkbox.Indicator>
                            </Checkbox.Root>
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
                      <Button
                        variant="secondary"
                        size="sm"
                        onClick={closeConfirmation}
                      >
                        {t("common.cancel")}
                      </Button>
                      <Button
                        variant={
                          confirmAction === "delete" ? "danger" : "primary"
                        }
                        size="sm"
                        onClick={() => {
                          const action = confirmAction;
                          acceptConfirmation();
                          void mutateServer(selected, (generation) =>
                            action === "delete"
                              ? onRemove(generation, selected.id)
                              : action === "allow_all"
                                ? onSetAllowedTools(
                                    generation,
                                    selected.id,
                                    selected.tools
                                      .filter(
                                        (tool) =>
                                          tool.desiredAllowed ||
                                          tool.discovered,
                                      )
                                      .map((tool) => tool.name),
                                  )
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
                      </Button>
                    </div>
                  </div>
                )}
              </div>
            ) : null}
          </Drawer.Popup>
        </Drawer.Portal>
      </Drawer.Root>
    </section>
  );
}
