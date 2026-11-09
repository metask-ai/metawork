import {
  McpInstallationCard,
  type McpInstallationActions,
} from "./McpInstallationCard.tsx";
import {
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

import type {
  McpManagementView,
  McpAuthorizationCancelResult,
  McpAuthorizationResult,
  McpConnectionTestResult,
  McpConfigurationApplyResult,
  McpHttpConnectionInput,
  McpMutationResult,
  McpCreateResult,
  McpInstallationOperation,
  McpRefreshResult,
  McpSecretSlot,
  McpStdioConnectionInput,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Alert } from "../../components/ui/alert.tsx";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Checkbox } from "../../components/ui/checkbox.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SearchField } from "../../components/ui/search-field.tsx";
import { SelectField } from "../../components/ui/select.tsx";
import { Switch } from "../../components/ui/switch.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  commandLineToken,
  parseMcpCommandLine,
  validMcpArgv,
  validMcpHttpEndpoint,
} from "./configuration-input.ts";
export {
  parseMcpCommandLine,
  validMcpHttpEndpoint,
} from "./configuration-input.ts";

type McpServer = McpManagementView["servers"][number];
type PaneState =
  | { kind: "add" }
  | { kind: "replace"; id: string }
  | { kind: "server"; id: string }
  | null;
type ConfirmAction = "enable" | "delete" | "allow_all";
type Confirmation = { action: ConfirmAction; serverId: string } | null;
type McpMutationSuccessNotice =
  "mcp.mutation.enabled" | "mcp.mutation.disabled";

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

function recoveringAuthorization(server: McpServer) {
  return (
    server.applyStatus === "waiting_auth" ||
    server.authorizationStatus === "refreshing"
  );
}

function serverNeedsAttention(server: McpServer, applying: boolean) {
  if (!server.desiredEnabled) return false;
  if (server.connection === null) return true;
  if (server.approvalStatus === "unapproved") return true;
  if (applying || recoveringAuthorization(server)) return false;
  return (
    !["not_required", "ready"].includes(server.authorizationStatus) ||
    ["pending", "rejected", "failed", "unknown"].includes(server.applyStatus) ||
    attentionStatuses.has(server.runtimeStatus) ||
    server.newTaskAccess === "unavailable"
  );
}

function serverStateKey(server: McpServer, applying: boolean) {
  if (server.connection === null)
    return "mcp.detail.connection_unavailable" as const;
  if (server.approvalStatus === "unapproved")
    return "mcp.approval.required" as const;
  if (!server.desiredEnabled) return "mcp.desired.disabled" as const;
  if (!["not_required", "ready"].includes(server.authorizationStatus))
    return `mcp.authorization_status.${server.authorizationStatus}` as const;
  if (server.applyStatus === "waiting_auth")
    return "mcp.apply_status.waiting_auth" as const;
  if (applying) return "mcp.status.connecting" as const;
  if (["pending", "rejected", "failed", "unknown"].includes(server.applyStatus))
    return `mcp.apply_status.${server.applyStatus}` as const;
  if (server.runtimeStatus !== "ready")
    return `mcp.status.${server.runtimeStatus}` as const;
  return `mcp.access.${server.newTaskAccess}` as const;
}

function serverVisualStatus(server: McpServer, applying: boolean) {
  if (server.connection === null) return "invalid_catalog" as const;
  if (server.approvalStatus === "unapproved") return "not_loaded" as const;
  if (!server.desiredEnabled) return "disabled" as const;
  if (applying || recoveringAuthorization(server)) return "connecting" as const;
  if (serverNeedsAttention(server, false)) return "attention" as const;
  return server.runtimeStatus;
}

function serverCanApply(server: McpServer) {
  return (
    server.connection !== null &&
    server.approvalStatus === "approved" &&
    server.desiredEnabled &&
    ["not_required", "ready"].includes(server.authorizationStatus) &&
    server.applyStatus !== "waiting_auth" &&
    server.applyStatus !== "unknown"
  );
}

function serverStateIcon(server: McpServer, applying: boolean) {
  if (applying) return "refresh" as const;
  if (serverNeedsAttention(server, false)) return "warning" as const;
  if (server.runtimeStatus === "ready") return "check" as const;
  return "mcp" as const;
}

function McpServerRow({
  server,
  applying,
  selected,
  toggleDisabled,
  onOpen,
  onToggle,
}: {
  server: McpServer;
  applying: boolean;
  selected: boolean;
  toggleDisabled: boolean;
  onOpen: (server: McpServer, trigger: HTMLElement) => void;
  onToggle: (server: McpServer, enabled: boolean, trigger: HTMLElement) => void;
}) {
  const { t } = useI18n();
  const enablementDescriptionId = useId();
  const available = server.tools.filter(
    (tool) => tool.availableToNewTasks,
  ).length;
  const enablementUnavailable =
    server.connection === null ||
    (!server.desiredEnabled && server.approvalStatus !== "approved");
  const enablementDescription =
    server.connection === null
      ? t("mcp.enablement.connection_unavailable")
      : server.approvalStatus !== "approved"
        ? t("mcp.enablement.approval_required")
        : null;
  return (
    <li
      className="mcp-server-row"
      data-status={serverVisualStatus(server, applying)}
      data-selected={selected}
    >
      <span className="mcp-status-rail" aria-hidden="true" />
      <button
        className="mcp-server-open focus-ring"
        aria-current={selected ? "true" : undefined}
        aria-haspopup="dialog"
        aria-expanded={selected}
        onClick={(event) => onOpen(server, event.currentTarget)}
      >
        <span className="mcp-server-icon" aria-hidden="true">
          <Icon name={serverStateIcon(server, applying)} />
        </span>
        <span className="mcp-server-identity">
          <strong>{server.displayName}</strong>
          <span>
            {t(`mcp.transport.${server.transport}`)} ·{" "}
            {t(`mcp.auth.${server.authMode}`)}
          </span>
        </span>
        <span className="mcp-server-tools">
          {t("mcp.tool_access_summary", {
            available,
            total: server.tools.length,
          })}
        </span>
        <span className="mcp-server-state">
          <strong>{t(serverStateKey(server, applying))}</strong>
          {server.taskReferenceCount > 0 && (
            <small>
              {t("mcp.tasks.count", { count: server.taskReferenceCount })}
            </small>
          )}
        </span>
        <Icon name="chevron-right" />
      </button>
      <span
        className="mcp-server-enablement"
        data-enabled={server.desiredEnabled}
      >
        <span className="mcp-server-enablement-label" aria-hidden="true">
          {server.desiredEnabled
            ? t("mcp.desired.enabled")
            : t("mcp.desired.disabled")}
        </span>
        <Switch.Root
          checked={server.desiredEnabled}
          disabled={toggleDisabled || enablementUnavailable}
          aria-label={t("mcp.enablement.label", {
            server: server.displayName,
          })}
          aria-describedby={
            enablementDescription ? enablementDescriptionId : undefined
          }
          title={t(
            server.desiredEnabled ? "mcp.disable.action" : "mcp.enable.action",
          )}
          onClick={(event) =>
            onToggle(server, !server.desiredEnabled, event.currentTarget)
          }
        >
          <Switch.Thumb />
        </Switch.Root>
        {enablementDescription && (
          <span id={enablementDescriptionId} className="sr-only">
            {enablementDescription}
          </span>
        )}
      </span>
    </li>
  );
}

function McpDetailDrawer({
  closeLocked,
  onClose,
  children,
}: {
  closeLocked: boolean;
  onClose: () => void;
  children: ReactNode;
}) {
  return (
    <Drawer.Root
      open
      onOpenChange={(open) => {
        if (!open && !closeLocked) onClose();
      }}
    >
      <Drawer.Portal>
        <Drawer.Backdrop />
        <Drawer.Popup
          className="mcp-detail-pane w-[min(620px,calc(100vw-28px))] max-[620px]:w-full bg-(--ui-surface-canvas) shadow-[-18px_0_54px_rgba(37,34,45,0.13)]"
          aria-labelledby="mcp-detail-title"
        >
          {children}
        </Drawer.Popup>
      </Drawer.Portal>
    </Drawer.Root>
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

function McpSecretInput({
  label,
  status,
  disabled,
  maxBytes,
  onSave,
}: {
  label: string;
  status: "missing" | "set";
  disabled: boolean;
  maxBytes: number;
  onSave: (secret: string) => Promise<McpMutationResult | null | undefined>;
}) {
  const { t, locale } = useI18n();
  return (
    <form
      key={`${disabled}:${maxBytes}`}
      className="mcp-secret-form"
      onSubmit={(event) => {
        event.preventDefault();
        if (disabled) return;
        const form = event.currentTarget;
        if (!form.reportValidity()) return;
        const secret = new FormData(form).get("secret");
        if (typeof secret !== "string" || secret.length === 0) return;
        form.reset();
        void onSave(secret);
      }}
      onReset={(event) => {
        const input = event.currentTarget.elements.namedItem("secret");
        if (input instanceof HTMLInputElement) input.setCustomValidity("");
      }}
    >
      <label>
        {label} · {t(`mcp.secret.${status}`)}
        <Input
          type="password"
          name="secret"
          aria-label={label}
          autoComplete="new-password"
          spellCheck={false}
          defaultValue=""
          disabled={disabled}
          required
          onChange={(event) => {
            const input = event.currentTarget;
            input.setCustomValidity(
              new TextEncoder().encode(input.value).length > maxBytes
                ? t("mcp.secret.too_long", {
                    maxBytes: maxBytes.toLocaleString(
                      locale === "pseudo" ? "en-US" : locale,
                    ),
                  })
                : "",
            );
          }}
        />
      </label>
      <footer>
        <Button type="submit" variant="secondary" size="sm" disabled={disabled}>
          {t("common.save")}
        </Button>
        <Button type="reset" variant="ghost" size="sm" disabled={disabled}>
          {t("common.cancel")}
        </Button>
      </footer>
    </form>
  );
}

export function McpPage({
  management,
  installationOperations = [],
  onCancelInstallation,
  onCaptureInstallation,
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
  onApply,
  onRefresh,
}: {
  management: McpManagementView;
  installationOperations?: McpInstallationOperation[];
  onCancelInstallation?: McpInstallationActions["onCancelInstallation"];
  onCaptureInstallation?: McpInstallationActions["onCaptureInstallation"];

  capabilities: {
    connectionApproval: boolean;
    secretCapture: boolean;
    secretMaxBytes: number;
    oauth: boolean;
  };
  query: string;
  disabled: boolean;
  onQuery: (query: string) => void;
  onCreateStdio: (
    expectedGeneration: string,
    input: McpStdioConnectionInput,
  ) => Promise<McpCreateResult>;
  onCreateHttp: (
    expectedGeneration: string,
    input: McpHttpConnectionInput,
  ) => Promise<McpCreateResult>;
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
    secret: string,
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
  onApply: (serverId?: string) => Promise<McpConfigurationApplyResult>;
  onRefresh: () => Promise<McpRefreshResult>;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const paneHeading = useRef<HTMLHeadingElement>(null);
  const confirmTrigger = useRef<HTMLElement | null>(null);
  const paneTrigger = useRef<HTMLElement | null>(null);
  const connectionSection = useRef<HTMLElement>(null);
  const toolSection = useRef<HTMLElement>(null);
  const [paneState, setPaneState] = useState<PaneState>(null);
  const [confirmation, setConfirmation] = useState<Confirmation>(null);
  const [pendingServerId, setPendingServerId] = useState<string | null>(null);
  const [createPending, setCreatePending] = useState(false);
  const [refreshPending, setRefreshPending] = useState(false);
  const [applyPending, setApplyPending] = useState(false);
  const [cancelPending, setCancelPending] = useState(false);
  const [displayName, setDisplayName] = useState("");
  const [transport, setTransport] = useState<"stdio" | "streamable_http">(
    "stdio",
  );
  const [negotiation, setNegotiation] = useState<
    "automatic" | "modern_only" | "compat_only"
  >("automatic");
  const [timeoutMs, setTimeoutMs] = useState("30000");
  const [commandLine, setCommandLine] = useState("");
  const [structuredArgv, setStructuredArgv] = useState<string[] | null>(null);
  const saveOperation = useRef<symbol | null>(null);
  useEffect(
    () => () => {
      saveOperation.current = null;
    },
    [],
  );
  const previousGeneration = useRef(management.desiredGeneration);
  useEffect(() => {
    if (
      previousGeneration.current !== management.desiredGeneration ||
      management.managementHealth !== "ready" ||
      disabled
    ) {
      previousGeneration.current = management.desiredGeneration;
      if (sensitiveEndpoint) setEndpoint("");
    }
    if (management.managementHealth !== "ready" || disabled)
      saveOperation.current = null;
  }, [management.desiredGeneration, management.managementHealth, disabled]);
  const [cwd, setCwd] = useState("");
  const [environmentNames, setEnvironmentNames] = useState<string[]>([]);
  const [stdioAuthMode, setStdioAuthMode] = useState<"none" | "static">("none");
  const [endpoint, setEndpoint] = useState("");
  const [sensitiveEndpoint, setSensitiveEndpoint] = useState(false);
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
    paneState && paneState.kind !== "add"
      ? (management.servers.find((server) => server.id === paneState.id) ??
        null)
      : null;
  const confirmationServer = confirmation
    ? (management.servers.find(
        (server) => server.id === confirmation.serverId,
      ) ?? null)
    : null;
  const isServerApplying = (server: McpServer) =>
    server.applyStatus === "applying";
  const attention = visibleServers.filter((server) =>
    serverNeedsAttention(server, isServerApplying(server)),
  );
  const available = visibleServers.filter(
    (server) =>
      !serverNeedsAttention(server, isServerApplying(server)) &&
      server.desiredEnabled,
  );
  const disabledServers = visibleServers.filter(
    (server) =>
      !serverNeedsAttention(server, isServerApplying(server)) &&
      !server.desiredEnabled,
  );
  const managementReady = management.managementHealth === "ready";
  const mutationLocked =
    disabled ||
    !managementReady ||
    management.operation !== "idle" ||
    management.configurationApply === "applying" ||
    management.desiredGeneration === null ||
    management.runtimeAlignment === "unknown" ||
    refreshPending;
  const refreshLocked =
    disabled ||
    management.runtimeUncertain ||
    !managementReady ||
    management.operation !== "idle" ||
    management.configurationApply === "applying" ||
    refreshPending ||
    createPending ||
    pendingServerId !== null ||
    management.authorizationOperation.kind !== "idle";
  const selectedOperationBusy =
    selected !== null &&
    ((management.authorizationOperation.kind !== "idle" &&
      management.authorizationOperation.serverId === selected.id) ||
      selected.connectionTest.status === "testing");
  const paneCloseLocked =
    createPending || pendingServerId !== null || selectedOperationBusy;
  const existingOAuthClientAuthMethod =
    paneState?.kind === "replace" &&
    selected?.authMode === "oauth" &&
    selected.connection?.kind === "streamable_http"
      ? selected.connection.tokenEndpointAuthMethod
      : null;
  const addValid =
    validMcpDisplayName(displayName) &&
    /^(?:[1-9][0-9]{0,8})$/.test(timeoutMs) &&
    (transport === "stdio"
      ? (structuredArgv !== null
          ? validMcpArgv(structuredArgv)
          : parseMcpCommandLine(commandLine) !== null) &&
        validMcpPublicText(cwd, false) &&
        validMcpNames(environmentNames) &&
        ((stdioAuthMode === "none" && environmentNames.length === 0) ||
          (stdioAuthMode === "static" && environmentNames.length > 0))
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
    if (!paneState) return;
    const frame = window.requestAnimationFrame(() =>
      paneHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [paneState?.kind, selected?.id]);

  useEffect(() => {
    if (paneState && paneState.kind !== "add" && !selected) closePane();
    // closePane restores focus to the surviving list context when the
    // authoritative projection removes the open server.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paneState, selected]);

  useEffect(() => {
    if (selected) setRenameDraft(selected.displayName);
  }, [selected?.id, selected?.displayName]);

  function openServer(server: McpServer, trigger: HTMLElement) {
    paneTrigger.current = trigger;
    setConfirmation(null);
    setNotice(null);
    setPaneState({ kind: "server", id: server.id });
  }

  function openAdd(trigger: HTMLElement) {
    paneTrigger.current = trigger;
    setDisplayName("");
    setTransport("stdio");
    setNegotiation("automatic");
    setTimeoutMs("30000");
    setCommandLine("");
    setStructuredArgv(null);
    setCwd("");
    setEnvironmentNames([]);
    setStdioAuthMode("none");
    setEndpoint("");
    setSensitiveEndpoint(false);
    setAuthMode("none");
    setHeaderNames([]);
    setRegistrationKind("automatic");
    setClientId("");
    setTokenEndpointAuthMethod("none");
    setNotice(null);
    setPaneState({ kind: "add" });
  }

  function openReplacement(server: McpServer) {
    const connection = server.connection;
    if (connection === null) return;
    setDisplayName(server.displayName);
    setTransport(server.transport);
    setNegotiation(server.negotiation);
    setTimeoutMs(String(server.timeoutMs));
    setCommandLine("");
    setStructuredArgv(
      connection.kind === "stdio"
        ? [connection.command, ...connection.arguments]
        : null,
    );
    setCwd(connection.kind === "stdio" ? (connection.cwd ?? "") : "");
    setEnvironmentNames(
      connection.kind === "stdio"
        ? connection.environment.map((slot) => slot.name)
        : [],
    );
    setStdioAuthMode(
      connection.kind === "stdio" && connection.environment.length > 0
        ? "static"
        : "none",
    );
    setEndpoint(
      connection.kind === "streamable_http" && !connection.sensitiveEndpoint
        ? connection.endpoint
        : "",
    );
    setSensitiveEndpoint(
      connection.kind === "streamable_http" && !!connection.sensitiveEndpoint,
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
    setPaneState({ kind: "replace", id: server.id });
  }

  const savedServer = useRef<{ id: string } | null>(null);

  useEffect(() => {
    // After the canonical projection includes a saved server, move from the
    // form to its detail. Testing remains an explicit next action.
    const pending = savedServer.current;
    if (!pending || !management.desiredGeneration) return;
    const server = management.servers.find((entry) => entry.id === pending.id);
    if (!server) return;
    savedServer.current = null;
    setPaneState({ kind: "server", id: server.id });
  });

  function closePane() {
    setEndpoint("");
    setSensitiveEndpoint(false);
    saveOperation.current = null;
    const trigger = paneTrigger.current;
    setPaneState(null);
    setConfirmation(null);
    confirmTrigger.current = null;
    window.requestAnimationFrame(() => {
      if (trigger?.isConnected) trigger.focus();
      else
        (
          document.querySelector<HTMLElement>(".mcp-server-open") ??
          title.current
        )?.focus();
    });
  }

  function openConfirmation(
    action: ConfirmAction,
    server: McpServer,
    trigger: HTMLElement,
  ) {
    confirmTrigger.current = trigger;
    setConfirmation({ action, serverId: server.id });
  }

  function closeConfirmation() {
    const trigger = confirmTrigger.current;
    setConfirmation(null);
    confirmTrigger.current = null;
    window.requestAnimationFrame(() => {
      if (trigger?.isConnected) trigger.focus();
    });
  }

  function acceptConfirmation(serverId: string) {
    const trigger = confirmTrigger.current;
    setConfirmation(null);
    confirmTrigger.current = null;
    window.requestAnimationFrame(() => {
      if (paneState?.kind !== "add" && paneState?.id === serverId)
        paneHeading.current?.focus();
      else if (trigger?.isConnected) trigger.focus();
      else title.current?.focus();
    });
  }

  function mutationNotice(
    result: McpMutationResult,
    successNotice?: McpMutationSuccessNotice,
  ) {
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
      text:
        result.outcome === "saved" && successNotice
          ? t(successNotice)
          : t(`mcp.mutation.${result.outcome}`),
    });
  }

  async function createServer() {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || !addValid || createPending) return;
    const operation = Symbol();
    saveOperation.current = operation;
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
          ? (() => {
              const parsedCommand =
                structuredArgv ?? parseMcpCommandLine(commandLine);
              if (parsedCommand === null) throw new Error("invalid command");
              return {
                ...shared,
                command: parsedCommand[0],
                arguments: parsedCommand.slice(1),
                cwd: cwd.trim() || null,
                environmentNames:
                  stdioAuthMode === "static"
                    ? environmentNames.map((value) => value.trim())
                    : [],
              } satisfies McpStdioConnectionInput;
            })()
          : ({
              ...shared,
              endpoint: endpoint.trim(),
              ...(sensitiveEndpoint ? { sensitiveEndpoint: true } : {}),
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
        paneState?.kind === "replace" && selected
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
      if (saveOperation.current !== operation) return;
      if (result.outcome === "saved") {
        const serverId =
          paneState?.kind === "replace" && selected
            ? selected.id
            : (result as McpCreateResult).serverId;
        if (!serverId || !result.desiredGeneration)
          throw Error("missing create receipt");
        savedServer.current = { id: serverId };
      } else if (result.outcome === "saved_recovery_required") closePane();
    } catch {
      setNotice({
        tone: "attention",
        text: t("mcp.mutation.failed"),
      });
    } finally {
      if (sensitiveEndpoint) setEndpoint("");
      if (saveOperation.current === operation) saveOperation.current = null;
      setCreatePending(false);
    }
  }

  async function mutateServer(
    server: McpServer,
    mutation: (generation: string) => Promise<McpMutationResult>,
    successNotice?: McpMutationSuccessNotice,
  ) {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || pendingServerId !== null) return;
    setPendingServerId(server.id);
    setNotice(null);
    try {
      const result = await mutation(generation);
      mutationNotice(result, successNotice);
      return result;
    } catch {
      setNotice({ tone: "attention", text: t("mcp.mutation.failed") });
      return null;
    } finally {
      setPendingServerId(null);
    }
  }

  function requestServerEnablement(
    server: McpServer,
    enabled: boolean,
    trigger: HTMLElement,
  ) {
    const restoresToolAccess =
      enabled && server.tools.some((tool) => tool.desiredAllowed);
    if (restoresToolAccess) {
      openConfirmation("enable", server, trigger);
      return;
    }
    void mutateServer(
      server,
      (generation) => onSetEnabled(generation, server.id, enabled),
      enabled ? "mcp.mutation.enabled" : "mcp.mutation.disabled",
    );
  }

  async function authorizeServer(server: McpServer) {
    const generation = management.desiredGeneration;
    if (!generation || mutationLocked || pendingServerId !== null) return;
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
    if (!generation || mutationLocked || pendingServerId !== null) return;
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

  async function applyConfiguration(serverId?: string) {
    if (
      applyPending ||
      management.runtimeUncertain ||
      management.configurationApply === "applying"
    )
      return;
    setApplyPending(true);
    setNotice(null);
    try {
      const result = await onApply(serverId);
      setNotice({
        tone: result.outcome === "started" ? "quiet" : "attention",
        text: t(`mcp.apply.${result.outcome}`),
      });
    } catch {
      setNotice({ tone: "attention", text: t("mcp.apply.unavailable") });
    } finally {
      setApplyPending(false);
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
            <McpServerRow
              key={server.id}
              server={server}
              applying={isServerApplying(server)}
              selected={selected?.id === server.id}
              toggleDisabled={
                mutationLocked ||
                pendingServerId !== null ||
                (management.authorizationOperation.kind !== "idle" &&
                  management.authorizationOperation.serverId === server.id) ||
                server.connectionTest.status === "testing"
              }
              onOpen={openServer}
              onToggle={requestServerEnablement}
            />
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
    if (management.runtimeUncertain)
      return (
        <Alert variant="warning" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.runtime_unknown.title")}</strong>
            <p>{t("mcp.banner.runtime_unknown.body")}</p>
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
    if (management.configurationApply === "applying")
      return (
        <Alert variant="neutral" className="mcp-state-banner">
          <Icon name="refresh" />
          <div>
            <strong>{t("mcp.banner.applying.title")}</strong>
            <p>{t("mcp.banner.applying.body")}</p>
          </div>
        </Alert>
      );
    if (management.authorizationOperation.kind !== "idle")
      return (
        <Alert variant="neutral" className="mcp-state-banner">
          <Icon name="refresh" />
          <div>
            <strong>
              {t(
                management.servers.some(
                  (server) => server.authorizationStatus === "refreshing",
                )
                  ? "mcp.authorization_status.refreshing"
                  : "mcp.banner.authorization.title",
              )}
            </strong>
            <p>{t("mcp.banner.authorization.body")}</p>
          </div>
        </Alert>
      );
    if (
      management.configurationApply === "failed" ||
      management.applyFailureCount > 0
    )
      return (
        <Alert variant="warning" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.apply_failed.title")}</strong>
            <p>{t("mcp.banner.apply_failed.body")}</p>
          </div>
          <Button
            variant="secondary"
            size="sm"
            disabled={applyPending}
            onClick={() => void applyConfiguration()}
          >
            {t("mcp.apply.action")}
          </Button>
        </Alert>
      );
    if (management.runtimeAlignment === "restart_required")
      return (
        <Alert variant="warning" className="mcp-state-banner">
          <Icon name="warning" />
          <div>
            <strong>{t("mcp.banner.apply_failed.title")}</strong>
            <p>{t("mcp.banner.apply_failed.body")}</p>
          </div>
          <Button
            variant="secondary"
            size="sm"
            disabled={applyPending}
            onClick={() => void applyConfiguration()}
          >
            {t("mcp.apply.action")}
          </Button>
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

  function nextActionCard(
    titleText: string,
    bodyText: string,
    action?: ReactNode,
  ) {
    return (
      <section className="mcp-next-action" aria-labelledby="mcp-next-action">
        <div>
          <Icon name="warning" />
          <span>
            <strong id="mcp-next-action">{titleText}</strong>
            <p>{bodyText}</p>
          </span>
        </div>
        {action}
      </section>
    );
  }

  function renderNextAction(server: McpServer) {
    const serverBusy =
      mutationLocked || pendingServerId !== null || selectedOperationBusy;
    if (server.connection === null)
      return nextActionCard(
        t("mcp.detail.connection_unavailable"),
        t("mcp.detail.connection_unavailable_help"),
      );

    if (management.configurationApply === "applying")
      return nextActionCard(
        t("mcp.banner.applying.title"),
        t("mcp.banner.applying.body"),
      );

    if (server.approvalStatus === "unapproved")
      return nextActionCard(
        t("mcp.approval.required"),
        t("mcp.approval.help"),
        capabilities.connectionApproval ? (
          <Button
            variant="primary"
            size="sm"
            disabled={serverBusy}
            onClick={() =>
              void mutateServer(server, (generation) =>
                onApprove(generation, server.id),
              )
            }
          >
            {t("mcp.approval.action")}
          </Button>
        ) : undefined,
      );

    if (!server.desiredEnabled) return null;

    if (
      server.authorizationStatus === "refreshing" ||
      server.applyStatus === "waiting_auth"
    )
      return nextActionCard(
        t(
          server.authorizationStatus === "refreshing"
            ? "mcp.authorization_status.refreshing"
            : "mcp.apply_status.waiting_auth",
        ),
        t("mcp.next.authorization_recovery.body"),
      );

    if (!["not_required", "ready"].includes(server.authorizationStatus)) {
      const operation = management.authorizationOperation;
      if (operation.kind !== "idle" && operation.serverId === server.id)
        return nextActionCard(
          t("mcp.next.authorization.title"),
          t(`mcp.authorization_phase.${operation.kind}`),
          <Button
            variant="secondary"
            size="sm"
            disabled={cancelPending}
            onClick={() => void cancelAuthorization()}
          >
            {t("mcp.authorization.cancel")}
          </Button>,
        );

      if (server.authMode === "oauth") {
        const clientSecretMissing =
          server.connection?.kind === "streamable_http" &&
          server.connection.registrationKind === "pre_registered" &&
          server.connection.clientSecretStatus === "missing";
        return nextActionCard(
          t(`mcp.authorization_status.${server.authorizationStatus}`),
          operation.kind !== "idle"
            ? t("mcp.authorization.busy")
            : clientSecretMissing &&
                (!capabilities.secretCapture ||
                  server.authorizationStatus === "capability_unavailable")
              ? t("mcp.capability.capture_unavailable")
              : t("mcp.next.authorization.body"),
          operation.kind === "idle" &&
            capabilities.oauth &&
            server.canAuthorize &&
            server.authorizationStatus !== "capability_unavailable" &&
            !clientSecretMissing ? (
            <Button
              variant="primary"
              size="sm"
              disabled={serverBusy}
              onClick={() => void authorizeServer(server)}
            >
              {server.authorizationStatus === "reauth_required"
                ? t("mcp.authorization.again")
                : t("mcp.authorization.action")}
            </Button>
          ) : clientSecretMissing &&
            capabilities.secretCapture &&
            server.authorizationStatus !== "capability_unavailable" ? (
            <Button
              variant="primary"
              size="sm"
              onClick={() =>
                connectionSection.current?.scrollIntoView({ block: "start" })
              }
            >
              {t("mcp.next.configure_credentials")}
            </Button>
          ) : undefined,
        );
      }

      return nextActionCard(
        t(`mcp.authorization_status.${server.authorizationStatus}`),
        capabilities.secretCapture
          ? t("mcp.next.credentials.body")
          : t("mcp.capability.capture_unavailable"),
        capabilities.secretCapture ? (
          <Button
            variant="primary"
            size="sm"
            onClick={() =>
              connectionSection.current?.scrollIntoView({ block: "start" })
            }
          >
            {t("mcp.next.configure_credentials")}
          </Button>
        ) : undefined,
      );
    }

    if (server.runtimeStatus !== "ready") {
      const needsApply =
        server.runtimeStatus === "not_loaded" &&
        ["pending", "rejected", "failed"].includes(server.applyStatus);
      return nextActionCard(
        t(`mcp.status.${server.runtimeStatus}`),
        server.runtimeStatus === "invalid_catalog"
          ? t("mcp.next.invalid_catalog.body")
          : t("mcp.next.retry_connection.body"),
        server.runtimeStatus === "invalid_catalog" ? undefined : (
          <>
            <Button
              variant="primary"
              size="sm"
              disabled={
                needsApply ? applyPending || mutationLocked : refreshLocked
              }
              onClick={() =>
                void (needsApply
                  ? applyConfiguration(server.id)
                  : refreshCatalog())
              }
            >
              {t("mcp.next.retry_connection.action")}
            </Button>
            {server.authMode === "oauth" &&
              capabilities.oauth &&
              server.canAuthorize && (
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={serverBusy}
                  onClick={() => void authorizeServer(server)}
                >
                  {t("mcp.authorization.again")}
                </Button>
              )}
          </>
        ),
      );
    }

    const discoveredTools = server.tools.filter((tool) => tool.discovered);
    if (discoveredTools.length > 0 && server.newTaskAccess === "not_allowed")
      return nextActionCard(
        t("mcp.next.choose_tools.title"),
        t("mcp.next.choose_tools.body", { count: discoveredTools.length }),
        <Button
          variant="primary"
          size="sm"
          disabled={serverBusy}
          onClick={() =>
            toolSection.current?.scrollIntoView({ block: "start" })
          }
        >
          {t("mcp.next.choose_tools.action")}
        </Button>,
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
      <>
        <div className="mcp-page-inner">
          <header className="mcp-header">
            <div>
              <h1 id="mcp-title" ref={title} tabIndex={-1}>
                {t("mcp.title")}
              </h1>
              <p>{t("mcp.subtitle")}</p>
            </div>
            {!empty && (
              <div className="mcp-header-actions">
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
            )}
          </header>

          {installationOperations
            .filter(
              (operation) =>
                operation.phase !== "ready" && operation.phase !== "cancelled",
            )
            .map((operation) => (
              <McpInstallationCard
                key={operation.serverId}
                operation={operation}
                disabled={disabled}
                secretMaxBytes={capabilities.secretMaxBytes}
                onCancelInstallation={onCancelInstallation}
                onCaptureInstallation={onCaptureInstallation}
              />
            ))}
          {renderBanner()}
          {management.retainedMemberCount > 0 && (
            <p className="mcp-operation-notice" aria-live="polite">
              {t("mcp.retained.summary", {
                count: management.retainedMemberCount,
              })}
            </p>
          )}

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

        {paneState !== null && (
          <McpDetailDrawer
            closeLocked={paneCloseLocked}
            onClose={() => closePane()}
          >
            <header>
              <div>
                <small>
                  {paneState?.kind === "add"
                    ? t("mcp.add.eyebrow")
                    : paneState?.kind === "replace"
                      ? t("mcp.edit.eyebrow")
                      : t("mcp.detail.eyebrow")}
                </small>
                <h2 id="mcp-detail-title" ref={paneHeading} tabIndex={-1}>
                  {paneState?.kind === "add"
                    ? t("mcp.add.title")
                    : paneState?.kind === "replace"
                      ? t("mcp.edit.title")
                      : selected?.displayName}
                </h2>
                {selected && <p>{selected.namespace}</p>}
              </div>
              <div className="mcp-detail-header-actions">
                {selected && paneState?.kind === "server" && (
                  <span
                    className="mcp-enabled-badge"
                    data-enabled={selected.desiredEnabled}
                  >
                    {selected.desiredEnabled
                      ? t("mcp.desired.enabled")
                      : t("mcp.desired.disabled")}
                  </span>
                )}
                <button
                  className="icon-button focus-ring"
                  aria-label={t("common.close")}
                  disabled={paneCloseLocked}
                  onClick={() => closePane()}
                >
                  <Icon name="close" />
                </button>
              </div>
            </header>

            {paneState?.kind === "add" || paneState?.kind === "replace" ? (
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
                      paneState?.kind === "replace"
                        ? "mcp.edit.intro"
                        : "mcp.add.intro",
                    )}
                  </p>
                  <fieldset className="mcp-transport-choice">
                    <legend>{t("mcp.add.transport")}</legend>
                    <button
                      type="button"
                      data-selected={transport === "stdio"}
                      disabled={paneState?.kind === "replace"}
                      onClick={() => setTransport("stdio")}
                    >
                      <Icon name="mcp" />
                      <span>
                        <strong>{t("mcp.transport.stdio")}</strong>
                        <small>{t("mcp.add.stdio_help")}</small>
                      </span>
                    </button>
                    <button
                      type="button"
                      data-selected={transport === "streamable_http"}
                      disabled={paneState?.kind === "replace"}
                      onClick={() => setTransport("streamable_http")}
                    >
                      <Icon name="mcp" />
                      <span>
                        <strong>{t("mcp.transport.streamable_http")}</strong>
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
                  {transport === "stdio" ? (
                    <>
                      {structuredArgv === null ? (
                        <label>
                          <span>{t("mcp.add.command")}</span>
                          <Input
                            autoComplete="off"
                            value={commandLine}
                            placeholder="npx -y @modelcontextprotocol/server-filesystem /workspace"
                            onChange={(event) =>
                              setCommandLine(event.target.value)
                            }
                          />
                          <small>{t("mcp.add.command_help")}</small>
                        </label>
                      ) : (
                        <fieldset className="mcp-structured-command">
                          <legend>{t("mcp.add.structured_command")}</legend>
                          <label>
                            <span>{t("mcp.add.executable")}</span>
                            <Input
                              autoComplete="off"
                              value={structuredArgv[0]}
                              onChange={(event) =>
                                setStructuredArgv([
                                  event.target.value,
                                  ...structuredArgv.slice(1),
                                ])
                              }
                            />
                          </label>
                          {structuredArgv.slice(1).map((argument, index) => (
                            <div className="mcp-argument-row" key={index}>
                              <label>
                                <span>
                                  {t("mcp.add.argument")} {index + 1}
                                </span>
                                <Input
                                  autoComplete="off"
                                  value={argument}
                                  onChange={(event) =>
                                    setStructuredArgv(
                                      structuredArgv.map((value, position) =>
                                        position === index + 1
                                          ? event.target.value
                                          : value,
                                      ),
                                    )
                                  }
                                />
                              </label>
                              <Button
                                type="button"
                                variant="ghost"
                                onClick={() =>
                                  setStructuredArgv(
                                    structuredArgv.filter(
                                      (_, position) => position !== index + 1,
                                    ),
                                  )
                                }
                              >
                                {t("mcp.add.remove_argument")}
                              </Button>
                            </div>
                          ))}
                          <Button
                            type="button"
                            variant="secondary"
                            disabled={structuredArgv.length > 128}
                            onClick={() =>
                              setStructuredArgv([...structuredArgv, ""])
                            }
                          >
                            {t("mcp.add.add_argument")}
                          </Button>
                          <Button
                            type="button"
                            variant="ghost"
                            onClick={() => {
                              setCommandLine(
                                structuredArgv
                                  .map((value) => commandLineToken(value))
                                  .join(" "),
                              );
                              setStructuredArgv(null);
                            }}
                          >
                            {t("mcp.add.edit_command_line")}
                          </Button>
                        </fieldset>
                      )}
                      <label>
                        <span>{t("mcp.add.cwd")}</span>
                        <Input
                          autoComplete="off"
                          value={cwd}
                          onChange={(event) => setCwd(event.target.value)}
                        />
                      </label>
                      <fieldset className="mcp-auth-choice">
                        <legend>{t("mcp.add.authentication")}</legend>
                        {(["none", "static"] as const).map((mode) => (
                          <label key={mode}>
                            <Input
                              type="radio"
                              name="mcp-stdio-auth-mode"
                              checked={stdioAuthMode === mode}
                              disabled={
                                mode === "static" &&
                                !capabilities.secretCapture &&
                                !(
                                  paneState?.kind === "replace" &&
                                  selected?.authMode === "static"
                                )
                              }
                              onChange={() => {
                                setStdioAuthMode(mode);
                                if (mode === "none") setEnvironmentNames([]);
                                else if (environmentNames.length === 0)
                                  setEnvironmentNames([""]);
                              }}
                            />
                            <span>
                              {t(`mcp.auth.${mode}`)}
                              {mode === "static" &&
                                !capabilities.secretCapture &&
                                !(
                                  paneState?.kind === "replace" &&
                                  selected?.authMode === "static"
                                ) && (
                                  <small>{t("mcp.auth.static_locked")}</small>
                                )}
                            </span>
                          </label>
                        ))}
                      </fieldset>
                      {stdioAuthMode === "static" && (
                        <McpTextRows
                          label={t("mcp.add.environment")}
                          addLabel={t("mcp.add.environment_name")}
                          values={environmentNames}
                          onChange={setEnvironmentNames}
                        />
                      )}
                    </>
                  ) : (
                    <>
                      <label>
                        <span id="mcp-add-endpoint-label">
                          {t("mcp.add.endpoint")}
                        </span>
                        <Input
                          autoComplete="off"
                          type={sensitiveEndpoint ? "password" : "text"}
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
                      <label>
                        <Input
                          type="checkbox"
                          checked={sensitiveEndpoint}
                          disabled={createPending}
                          onChange={(event) => {
                            setEndpoint("");
                            setSensitiveEndpoint(event.target.checked);
                          }}
                        />
                        {t("mcp.add.sensitive_endpoint")}
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
                                    paneState?.kind === "replace" &&
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
                                  paneState?.kind === "replace" &&
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
                                      disabled:
                                        !capabilities.secretCapture &&
                                        existingOAuthClientAuthMethod !==
                                          "client_secret_basic",
                                    },
                                    {
                                      value: "client_secret_post",
                                      label: t(
                                        "mcp.client_auth.client_secret_post",
                                      ),
                                      disabled:
                                        !capabilities.secretCapture &&
                                        existingOAuthClientAuthMethod !==
                                          "client_secret_post",
                                    },
                                  ]}
                                  aria-label={t("mcp.add.client_auth_method")}
                                />
                                {!capabilities.secretCapture && (
                                  <small>
                                    {t("mcp.auth.oauth_secret_locked")}
                                  </small>
                                )}
                              </label>
                            </>
                          )}
                        </div>
                      )}
                    </>
                  )}
                  <details className="mcp-advanced mcp-form-advanced">
                    <summary>
                      <span>{t("mcp.detail.advanced")}</span>
                      <Icon name="chevron" />
                    </summary>
                    <div className="mcp-form-pair">
                      <label>
                        <span>{t("mcp.add.protocol")}</span>
                        <SelectField
                          value={negotiation}
                          onValueChange={(value) =>
                            setNegotiation(value as typeof negotiation)
                          }
                          options={[
                            {
                              value: "automatic",
                              label: t("mcp.negotiation.automatic"),
                            },
                            {
                              value: "modern_only",
                              label: t("mcp.negotiation.modern_only"),
                            },
                            {
                              value: "compat_only",
                              label: t("mcp.negotiation.compat_only"),
                            },
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
                        <small>
                          {t("mcp.add.timeoutHelp", {
                            limit: management.runtimeTimeoutLimitMs,
                          })}
                        </small>
                      </label>
                    </div>
                  </details>
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
                    onClick={() => closePane()}
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
                      : paneState?.kind === "replace"
                        ? t("mcp.edit.submit")
                        : t("mcp.add.submit")}
                  </Button>
                </footer>
              </form>
            ) : selected ? (
              <div className="mcp-detail-body">
                <section
                  className="mcp-connection-trace"
                  aria-label={t("mcp.trace.label")}
                >
                  {(
                    [
                      [
                        "connection",
                        selected.transport === "stdio"
                          ? selected.connection?.kind === "stdio"
                            ? selected.connection.command
                            : t("mcp.detail.connection_unavailable")
                          : selected.connection?.kind === "streamable_http"
                            ? selected.connection.endpoint
                            : t("mcp.detail.connection_unavailable"),
                        recoveringAuthorization(selected)
                          ? "active"
                          : serverCanApply(selected)
                            ? "complete"
                            : "attention",
                      ],
                      [
                        "handshake",
                        t(`mcp.status.${selected.runtimeStatus}`),
                        selected.runtimeStatus === "ready"
                          ? "complete"
                          : isServerApplying(selected)
                            ? "active"
                            : serverCanApply(selected)
                              ? "attention"
                              : "pending",
                      ],
                      [
                        "tools",
                        t("mcp.detail.allowed_count", {
                          allowed: selected.tools.filter(
                            (tool) => tool.desiredAllowed,
                          ).length,
                          total: selected.tools.length,
                        }),
                        selected.newTaskAccess === "available"
                          ? "complete"
                          : selected.runtimeStatus === "ready" &&
                              selected.tools.some((tool) => tool.discovered)
                            ? "active"
                            : "pending",
                      ],
                    ] as const
                  ).map(([step, summary, state], index) => (
                    <div key={step} data-state={state}>
                      <span aria-hidden="true">
                        {state === "complete" ? "✓" : index + 1}
                      </span>
                      <strong>{t(`mcp.trace.${step}`)}</strong>
                      <small>{summary}</small>
                    </div>
                  ))}
                </section>

                {!selected.desiredEnabled &&
                  selected.taskReferenceCount > 0 && (
                    <p className="mcp-operation-notice">
                      {t("mcp.retained.disabled_body")}
                    </p>
                  )}
                {renderNextAction(selected)}

                {selected.safeDiagnostic &&
                  !recoveringAuthorization(selected) && (
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

                <section className="mcp-tool-catalog" ref={toolSection}>
                  <header>
                    <div>
                      <h3>{t("mcp.detail.tool_permissions")}</h3>
                      <p>{t("mcp.detail.tool_help")}</p>
                    </div>
                    <span>
                      {
                        selected.tools.filter((tool) => tool.desiredAllowed)
                          .length
                      }
                      /{selected.tools.length}
                    </span>
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
                              className="size-[18px] rounded-[5px]"
                              checked={tool.desiredAllowed}
                              disabled={
                                mutationLocked ||
                                pendingServerId !== null ||
                                selectedOperationBusy ||
                                selected.connection === null
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
                  {selected.tools.some(
                    (tool) => tool.discovered && !tool.desiredAllowed,
                  ) && (
                    <div className="mcp-tool-actions">
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={
                          mutationLocked ||
                          pendingServerId !== null ||
                          selectedOperationBusy ||
                          selected.connection === null
                        }
                        onClick={(event) =>
                          openConfirmation(
                            "allow_all",
                            selected,
                            event.currentTarget,
                          )
                        }
                      >
                        {t("mcp.detail.allow_all", {
                          count: selected.tools.filter(
                            (tool) => tool.discovered && !tool.desiredAllowed,
                          ).length,
                        })}
                      </Button>
                    </div>
                  )}
                </section>

                <section className="mcp-detail-section" ref={connectionSection}>
                  <header>
                    <div>
                      <h3>{t("mcp.detail.connection_and_auth")}</h3>
                      <p>
                        {t(`mcp.transport.${selected.transport}`)} ·{" "}
                        {t(`mcp.auth.${selected.authMode}`)}
                      </p>
                    </div>
                    <div className="mcp-connection-actions">
                      {selected.connection !== null &&
                        ["not_required", "ready"].includes(
                          selected.authorizationStatus,
                        ) &&
                        selected.connectionTest.status !== "testing" && (
                          <Button
                            variant="secondary"
                            size="sm"
                            disabled={
                              mutationLocked ||
                              pendingServerId !== null ||
                              selectedOperationBusy
                            }
                            onClick={() => void testConnection(selected)}
                          >
                            {t("mcp.test.action")}
                          </Button>
                        )}
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={
                          mutationLocked ||
                          pendingServerId !== null ||
                          selectedOperationBusy ||
                          selected.connection === null
                        }
                        onClick={() => openReplacement(selected)}
                      >
                        {t("mcp.edit.action")}
                      </Button>
                    </div>
                  </header>

                  <div className="mcp-connection-overview">
                    {selected.connection?.kind === "stdio" ? (
                      <div>
                        <Icon name="mcp" />
                        <span>
                          <strong>{t("mcp.detail.executable")}</strong>
                          <code>{selected.connection.command}</code>
                        </span>
                      </div>
                    ) : selected.connection?.kind === "streamable_http" ? (
                      <div>
                        <Icon name="mcp" />
                        <span>
                          <strong>{t("mcp.add.endpoint")}</strong>
                          <code>{selected.connection.endpoint}</code>
                        </span>
                      </div>
                    ) : (
                      <div data-tone="attention">
                        <Icon name="warning" />
                        <span>
                          <strong>
                            {t("mcp.detail.connection_unavailable")}
                          </strong>
                          <small>
                            {t("mcp.detail.connection_unavailable_help")}
                          </small>
                        </span>
                      </div>
                    )}
                    <div
                      data-tone={
                        ["not_required", "ready"].includes(
                          selected.authorizationStatus,
                        )
                          ? "ready"
                          : "attention"
                      }
                    >
                      <Icon
                        name={
                          ["not_required", "ready"].includes(
                            selected.authorizationStatus,
                          )
                            ? "check"
                            : "warning"
                        }
                      />
                      <span>
                        <strong>{t("mcp.detail.authorization")}</strong>
                        <small>
                          {t(
                            `mcp.authorization_status.${selected.authorizationStatus}`,
                          )}
                        </small>
                      </span>
                    </div>
                    {selected.connectionTest.status !== "untested" && (
                      <div
                        data-tone={
                          selected.connectionTest.status === "connected"
                            ? "ready"
                            : selected.connectionTest.status === "failed"
                              ? "attention"
                              : undefined
                        }
                      >
                        <Icon
                          name={
                            selected.connectionTest.status === "connected"
                              ? "check"
                              : selected.connectionTest.status === "failed"
                                ? "warning"
                                : "refresh"
                          }
                        />
                        <span>
                          <strong>{t("mcp.detail.connection_test")}</strong>
                          <small>
                            {selected.connectionTest.status === "connected"
                              ? t("mcp.test.summary.connected", {
                                  tools: selected.connectionTest.toolCount,
                                })
                              : selected.connectionTest.status === "failed"
                                ? t("mcp.test.summary.failed", {
                                    issues: selected.connectionTest.issueCount,
                                  })
                                : t("mcp.test.summary.testing")}
                          </small>
                        </span>
                      </div>
                    )}
                  </div>

                  {selected.authMode === "static" && (
                    <ul className="mcp-secret-slots">
                      {(selected.connection?.kind === "stdio"
                        ? selected.connection.environment
                        : selected.connection?.kind === "streamable_http"
                          ? selected.connection.headers
                          : []
                      ).map((slot) => (
                        <li key={slot.name}>
                          <McpSecretInput
                            key={JSON.stringify([
                              selected.id,
                              management.desiredGeneration,
                              slot.name,
                            ])}
                            label={slot.name}
                            status={slot.status}
                            maxBytes={capabilities.secretMaxBytes}
                            disabled={
                              !capabilities.secretCapture ||
                              mutationLocked ||
                              pendingServerId !== null ||
                              selectedOperationBusy ||
                              selected.approvalStatus !== "approved"
                            }
                            onSave={(secret) =>
                              mutateServer(selected, (generation) =>
                                onCaptureSecret(
                                  generation,
                                  selected.id,
                                  {
                                    kind:
                                      selected.transport === "stdio"
                                        ? "stdio_environment"
                                        : "http_header",
                                    name: slot.name,
                                  },
                                  secret,
                                ),
                              )
                            }
                          />
                        </li>
                      ))}
                    </ul>
                  )}

                  {selected.authMode === "oauth" &&
                    selected.connection?.kind === "streamable_http" &&
                    selected.connection.registrationKind === "pre_registered" &&
                    selected.connection.clientSecretStatus !==
                      "not_required" && (
                      <McpSecretInput
                        key={JSON.stringify([
                          selected.id,
                          management.desiredGeneration,
                          "oauth_client_secret",
                        ])}
                        label={t("mcp.secret.client_secret")}
                        status={selected.connection.clientSecretStatus}
                        maxBytes={capabilities.secretMaxBytes}
                        disabled={
                          !capabilities.secretCapture ||
                          mutationLocked ||
                          pendingServerId !== null ||
                          selectedOperationBusy ||
                          selected.approvalStatus !== "approved"
                        }
                        onSave={(secret) =>
                          mutateServer(selected, (generation) =>
                            onCaptureSecret(
                              generation,
                              selected.id,
                              { kind: "oauth_client_secret" },
                              secret,
                            ),
                          )
                        }
                      />
                    )}

                  <details className="mcp-advanced">
                    <summary>
                      <span>{t("mcp.detail.advanced")}</span>
                      <Icon name="chevron" />
                    </summary>
                    <div className="mcp-advanced-content">
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
                            onRename(
                              generation,
                              selected.id,
                              renameDraft.trim(),
                            ),
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
                              pendingServerId !== null ||
                              selectedOperationBusy ||
                              selected.connection === null
                            }
                            onChange={(event) =>
                              setRenameDraft(event.target.value)
                            }
                          />
                        </label>
                        <Button
                          type="submit"
                          variant="secondary"
                          size="sm"
                          disabled={
                            mutationLocked ||
                            pendingServerId !== null ||
                            selectedOperationBusy ||
                            selected.connection === null ||
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
                          <dd>
                            {t(`mcp.negotiation.${selected.negotiation}`)}
                          </dd>
                        </div>
                        <div>
                          <dt>{t("mcp.add.timeout")}</dt>
                          <dd>
                            {selected.timeoutMs}
                            {selected.timeoutMs >
                              management.runtimeTimeoutLimitMs && (
                              <small>
                                {t("mcp.add.timeoutHelp", {
                                  limit: management.runtimeTimeoutLimitMs,
                                })}
                              </small>
                            )}
                          </dd>
                        </div>
                        <div>
                          <dt>{t("mcp.detail.authentication")}</dt>
                          <dd>{t(`mcp.auth.${selected.authMode}`)}</dd>
                        </div>
                        {selected.connection?.kind === "stdio" ? (
                          <>
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
                                      <code>
                                        {selected.connection.clientId}
                                      </code>
                                    </dd>
                                  </div>
                                )}
                              </>
                            )}
                          </>
                        ) : null}
                      </dl>
                    </div>
                  </details>

                  <p className="mcp-existing-task-note">
                    {t("mcp.existing_tasks_note")}
                  </p>
                </section>

                <section className="mcp-server-controls">
                  {!selected.desiredEnabled &&
                    selected.approvalStatus === "approved" &&
                    selected.connection !== null && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={
                          mutationLocked ||
                          pendingServerId !== null ||
                          selectedOperationBusy
                        }
                        onClick={(event) =>
                          requestServerEnablement(
                            selected,
                            true,
                            event.currentTarget,
                          )
                        }
                      >
                        {t("mcp.enable.action")}
                      </Button>
                    )}
                  {selected.desiredEnabled && selected.connection !== null && (
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={
                        mutationLocked ||
                        pendingServerId !== null ||
                        selectedOperationBusy
                      }
                      onClick={(event) =>
                        requestServerEnablement(
                          selected,
                          false,
                          event.currentTarget,
                        )
                      }
                    >
                      {t("mcp.disable.action")}
                    </Button>
                  )}
                  <Button
                    variant="danger"
                    size="sm"
                    disabled={
                      mutationLocked ||
                      pendingServerId !== null ||
                      selectedOperationBusy
                    }
                    onClick={(event) =>
                      openConfirmation("delete", selected, event.currentTarget)
                    }
                  >
                    <Icon name="trash" />
                    {t("mcp.delete.action")}
                  </Button>
                </section>
              </div>
            ) : null}
          </McpDetailDrawer>
        )}
      </>
      {confirmationServer && confirmation && (
        <AlertDialog.Root
          open
          onOpenChange={(open) => {
            if (!open) closeConfirmation();
          }}
        >
          <AlertDialog.Portal>
            <AlertDialog.Backdrop />
            <AlertDialog.Popup>
              <AlertDialog.Title>
                {t(`mcp.confirm.${confirmation.action}.title`)}
              </AlertDialog.Title>
              <AlertDialog.Description>
                {confirmation.action === "enable"
                  ? t("mcp.confirm.enable.body", {
                      count: confirmationServer.tools.filter(
                        (tool) => tool.desiredAllowed,
                      ).length,
                    })
                  : t(`mcp.confirm.${confirmation.action}.body`)}
                {confirmation.action === "delete" &&
                  confirmationServer.authMode === "oauth" && (
                    <> {t("mcp.confirm.delete.oauth_body")}</>
                  )}
              </AlertDialog.Description>
              <div className="mcp-confirm-actions">
                <Button
                  autoFocus
                  variant="secondary"
                  size="sm"
                  onClick={closeConfirmation}
                >
                  {t("common.cancel")}
                </Button>
                <Button
                  variant={
                    confirmation.action === "delete" ? "danger" : "primary"
                  }
                  size="sm"
                  onClick={() => {
                    const { action } = confirmation;
                    const target = confirmationServer;
                    acceptConfirmation(target.id);
                    void mutateServer(
                      target,
                      (generation) =>
                        action === "delete"
                          ? onRemove(generation, target.id)
                          : action === "allow_all"
                            ? onSetAllowedTools(
                                generation,
                                target.id,
                                target.tools
                                  .filter(
                                    (tool) =>
                                      tool.desiredAllowed || tool.discovered,
                                  )
                                  .map((tool) => tool.name),
                              )
                            : onSetEnabled(generation, target.id, true),
                      action === "enable" ? "mcp.mutation.enabled" : undefined,
                    ).then((result) => {
                      if (
                        action === "delete" &&
                        selected?.id === target.id &&
                        (result?.outcome === "saved" ||
                          result?.outcome === "saved_recovery_required")
                      )
                        closePane();
                    });
                  }}
                >
                  {t(`mcp.confirm.${confirmation.action}.action`)}
                </Button>
              </div>
            </AlertDialog.Popup>
          </AlertDialog.Portal>
        </AlertDialog.Root>
      )}
    </section>
  );
}
