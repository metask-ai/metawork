import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import type { BridgeClient } from "../../bridge/client.ts";
import type {
  HandoffSource,
  HandoffSessions,
  InboxMessage,
  TaskSummary,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";
import { matchingDrafts, type HandoffDraft } from "./handoff-drafts.ts";

type Actions = {
  client: Pick<BridgeClient, "handoffSessions" | "changeHandoff">;
  account: string | null;
  binding: string;
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  drafts: HandoffDraft[];
  onVerify(source: HandoffSource, storeId: string): void;
  onResume(draft: HandoffDraft): void;
  onCreate(source: HandoffSource, store: string, message?: InboxMessage): void;
  onOpen(taskId: string, quote?: { message: InboxMessage; id: string }): void;
};
const Context = createContext<
  | (Actions & {
      lists: Record<string, HandoffSessions | null>;
      refresh(): void;
    })
  | null
>(null);

export function InboxHandoffProvider({
  children,
  ids,
  revision,
  ...actions
}: Actions & { children: ReactNode; ids: string[]; revision: string }) {
  const { binding, account, client } = actions;
  const key = JSON.stringify([...new Set(ids)].sort());
  const [version, bump] = useState(0);
  const token = JSON.stringify([key, account, binding, revision, version]);
  const [result, setResult] = useState<{
    token: string;
    lists: Record<string, HandoffSessions | null>;
  } | null>(null);
  useEffect(() => {
    let current = true;
    async function read() {
      if (!account) return;
      const ids: string[] = JSON.parse(key);
      const lists: Record<string, HandoffSessions | null> = Object.create(null);
      for (const id of ids) {
        if (!current) return;
        lists[id] = await client
          .handoffSessions(binding, account, id)
          .catch(() => null);
      }
      if (current) setResult({ token, lists });
    }
    void read();
    return () => {
      current = false;
    };
  }, [token, key, client, binding, account]);
  return (
    <Context.Provider
      value={{
        ...actions,
        lists: result?.token === token ? result.lists : Object.create(null),
        refresh: () => bump((v) => v + 1),
      }}
    >
      {children}
    </Context.Provider>
  );
}

export function HandoffControls({
  referenced,
  canonical,
  message,
}: {
  referenced: string;
  canonical?: string;
  message?: InboxMessage;
}) {
  const api = useContext(Context);
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(false);
  const [target, setTarget] = useState("");
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const list = api?.lists[referenced];
  const onVerify = api?.onVerify;
  const account = api?.account;
  const binding = api?.binding;
  useEffect(() => {
    if (onVerify && account && binding && canonical && list)
      onVerify({ binding, account, referenced, canonical }, list.storeId);
  }, [onVerify, account, binding, referenced, canonical, list]);
  if (!api) return null;
  if (!list || !api.account)
    return canonical ? (
      <p role="status">
        {t(
          list === null || !api.account
            ? "handoff.unavailable"
            : "handoff.loading",
        )}
      </p>
    ) : null;
  const source = {
    binding: api.binding,
    account: api.account,
    referenced,
    canonical: canonical ?? referenced,
  };
  const sessions = list.sessions.flatMap((link) => {
    const task = api.tasks.find((item) => item.id === link.taskId);
    return task
      ? [
          {
            task,
            preferred: link.preferred,
            workspace: api.workspaces.find((w) => w.id === task.workspaceId),
          },
        ]
      : [];
  });
  const drafts = matchingDrafts(
    api.drafts,
    api.account,
    list.storeId,
    referenced,
    source.canonical,
  );
  const active = sessions.filter(
    (s) =>
      !s.task.archived &&
      !s.task.historyReadOnly &&
      s.task.lifecycle === "open" &&
      s.task.deletionStatus === "idle",
  );
  const primary =
    active.find((s) => s.preferred) ??
    (sessions.length === 1 ? sessions[0] : undefined);
  const eligible = api.tasks.filter(
    (task) =>
      !task.archived &&
      !task.historyReadOnly &&
      task.lifecycle === "open" &&
      task.deletionStatus === "idle" &&
      !sessions.some((s) => s.task.id === task.id),
  );
  async function mutate(action: "link" | "prefer" | "unlink", id: string) {
    if (!api || !list || !canonical || busy) return;
    setBusy(true);
    setFailed(false);
    try {
      await api.client.changeHandoff(source, list.storeId, action, id);
      setTarget("");
      api.refresh();
    } catch {
      setFailed(true);
      api.refresh();
    } finally {
      setBusy(false);
    }
  }
  if (!canonical && !sessions.length && !drafts.length) return null;
  const showSessions = canonical || expanded;
  function label(s: (typeof sessions)[number]) {
    return (
      t(
        s.task.archived || s.task.historyReadOnly
          ? "handoff.history"
          : s.workspace?.authorization !== "available"
            ? "handoff.reauthorize"
            : "handoff.continue",
      ) +
      " · " +
      s.task.title
    );
  }
  return (
    <div className="inbox-handoff">
      {!canonical && (sessions.length > 1 || drafts.length > 1) && (
        <Button
          size="sm"
          variant="ghost"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {t("handoff.choose")} ({sessions.length + drafts.length})
        </Button>
      )}
      {!showSessions && primary && (
        <Button
          size="sm"
          variant="ghost"
          onClick={() => api.onOpen(primary.task.id)}
        >
          {label(primary)}
        </Button>
      )}
      {showSessions &&
        sessions.map((s) => (
          <div className="inbox-handoff-row" key={s.task.id}>
            <Button
              size="sm"
              variant="ghost"
              title={s.workspace?.canonicalRoot}
              onClick={() => api.onOpen(s.task.id)}
            >
              {label(s)}
              {s.preferred && sessions.length > 1
                ? " · " + t("handoff.default")
                : ""}
            </Button>
            {canonical && (
              <>
                {message && !s.task.archived && !s.task.historyReadOnly && (
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() =>
                      api.onOpen(s.task.id, { message, id: source.canonical })
                    }
                  >
                    {t("handoff.quote")}
                  </Button>
                )}
                {!s.preferred && !s.task.archived && (
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={busy}
                    onClick={() => void mutate("prefer", s.task.id)}
                  >
                    {t("handoff.prefer")}
                  </Button>
                )}
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={busy}
                  onClick={() => void mutate("unlink", s.task.id)}
                >
                  {t("handoff.unlink")}
                </Button>
              </>
            )}
          </div>
        ))}
      {(showSessions || drafts.length === 1) &&
        drafts.map((draft, i) => (
          <Button
            size="sm"
            variant="ghost"
            key={draft.operationId}
            onClick={() => api.onResume(draft)}
          >
            {t("handoff.resume")}
            {drafts.length > 1 ? " " + (i + 1) : ""}
          </Button>
        ))}
      {canonical && (
        <>
          <Button
            size="sm"
            variant="secondary"
            disabled={busy}
            onClick={() => api.onCreate(source, list.storeId, message)}
          >
            {t(drafts.length ? "handoff.another" : "handoff.new")}
          </Button>
          {eligible.length > 0 && (
            <div className="inbox-handoff-row">
              <select
                aria-label={t("handoff.link")}
                value={target}
                onChange={(e) => setTarget(e.target.value)}
              >
                <option value="">{t("handoff.pick")}</option>
                {eligible.map((task) => (
                  <option key={task.id} value={task.id}>
                    {task.title} ·{" "}
                    {
                      api.workspaces.find((w) => w.id === task.workspaceId)
                        ?.canonicalRoot
                    }
                  </option>
                ))}
              </select>
              <Button
                size="sm"
                variant="secondary"
                disabled={busy || !target}
                onClick={() => void mutate("link", target)}
              >
                {t("handoff.link")}
              </Button>
            </div>
          )}
        </>
      )}
      {failed && <p role="alert">{t("handoff.change_failed")}</p>}
    </div>
  );
}
