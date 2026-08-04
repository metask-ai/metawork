import { useEffect, useMemo, useRef, useState } from "react";

import type { McpManagementView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

type McpServer = McpManagementView["servers"][number];

const attentionStatuses = new Set<McpServer["status"]>([
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

function McpServerRow({
  server,
  onOpen,
}: {
  server: McpServer;
  onOpen: (server: McpServer, trigger: HTMLElement) => void;
}) {
  const { t } = useI18n();
  return (
    <li>
      <button
        className="mcp-server-row focus-ring"
        data-status={server.status}
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
          {t(
            server.tools.length === 1
              ? "mcp.tool_count.one"
              : "mcp.tool_count.other",
            { count: server.tools.length },
          )}
        </span>
        <span className="mcp-server-state">
          {t(`mcp.status.${server.status}`)}
        </span>
        <Icon name="chevron-right" />
      </button>
    </li>
  );
}

export function McpPage({
  management,
  query,
  onQuery,
}: {
  management: McpManagementView;
  query: string;
  onQuery: (query: string) => void;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const drawer = useRef<HTMLElement>(null);
  const drawerHeading = useRef<HTMLHeadingElement>(null);
  const drawerTrigger = useRef<HTMLElement | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const visibleServers = useMemo(
    () => filterMcpServers(management.servers, query),
    [management.servers, query],
  );
  const selected =
    management.servers.find((server) => server.id === selectedId) ?? null;
  const attention = visibleServers.filter((server) =>
    attentionStatuses.has(server.status),
  );
  const ready = visibleServers.filter((server) => server.status === "ready");
  const disabled = visibleServers.filter(
    (server) => server.status === "disabled",
  );

  useEffect(() => title.current?.focus(), []);

  useEffect(() => {
    if (!selected) return;
    const frame = window.requestAnimationFrame(() =>
      drawerHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [selected]);

  useEffect(() => {
    if (selectedId && !selected) setSelectedId(null);
  }, [selected, selectedId]);

  useEffect(() => {
    if (!selected) return;
    function keydown(event: KeyboardEvent) {
      if (event.key === "Escape") closeDetail();
      if (event.key !== "Tab" || !drawer.current) return;
      const focusable = Array.from(
        drawer.current.querySelectorAll<HTMLElement>(
          'button:not(:disabled), [tabindex="0"]',
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

  function openDetail(server: McpServer, trigger: HTMLElement) {
    drawerTrigger.current = trigger;
    setSelectedId(server.id);
  }

  function closeDetail() {
    const trigger = drawerTrigger.current;
    setSelectedId(null);
    window.requestAnimationFrame(() => {
      if (trigger?.isConnected) trigger.focus();
    });
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
            <McpServerRow key={server.id} server={server} onOpen={openDetail} />
          ))}
        </ul>
      </section>
    );
  }

  const unavailable = management.availability === "unavailable";
  const empty = management.servers.length === 0;
  const noResults = !empty && visibleServers.length === 0;

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
          {management.generation && (
            <span className="mcp-catalog-revision">
              {t("mcp.catalog_generation", {
                generation: management.generation,
              })}
            </span>
          )}
        </header>

        {!unavailable && !empty && (
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
        )}

        {unavailable ? (
          <div className="mcp-empty-state">
            <span>
              <Icon name="warning" />
            </span>
            <h2>{t("mcp.unavailable_title")}</h2>
            <p>{t("mcp.unavailable_body")}</p>
          </div>
        ) : empty ? (
          <div className="mcp-empty-state">
            <span>
              <Icon name="mcp" />
            </span>
            <h2>{t("mcp.empty_title")}</h2>
            <p>{t("mcp.empty_body")}</p>
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
            {renderGroup(t("mcp.section.available"), ready)}
            {renderGroup(t("mcp.section.disabled"), disabled)}
          </div>
        )}
      </div>

      {selected && (
        <div
          className="mcp-drawer-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeDetail();
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
                <small>{t("mcp.detail.eyebrow")}</small>
                <h2 id="mcp-drawer-title" ref={drawerHeading} tabIndex={-1}>
                  {selected.displayName}
                </h2>
                <p>{selected.namespace}</p>
              </div>
              <button
                className="icon-button focus-ring"
                aria-label={t("common.close")}
                onClick={closeDetail}
              >
                <Icon name="close" />
              </button>
            </header>

            <div className="mcp-detail-body">
              <dl className="mcp-detail-facts">
                <div>
                  <dt>{t("mcp.detail.status")}</dt>
                  <dd data-status={selected.status}>
                    {t(`mcp.status.${selected.status}`)}
                  </dd>
                </div>
                <div>
                  <dt>{t("mcp.detail.transport")}</dt>
                  <dd>{t(`mcp.transport.${selected.transport}`)}</dd>
                </div>
                <div>
                  <dt>{t("mcp.detail.tools")}</dt>
                  <dd>{selected.tools.length}</dd>
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

              <section className="mcp-tool-catalog">
                <header>
                  <h3>{t("mcp.detail.tool_catalog")}</h3>
                  <span>{selected.tools.length}</span>
                </header>
                {selected.tools.length === 0 ? (
                  <p className="mcp-no-tools">{t("mcp.detail.no_tools")}</p>
                ) : (
                  <ul>
                    {selected.tools.map((tool) => (
                      <li key={tool.name}>
                        <code>{tool.name}</code>
                      </li>
                    ))}
                  </ul>
                )}
              </section>
            </div>
          </aside>
        </div>
      )}
    </section>
  );
}
