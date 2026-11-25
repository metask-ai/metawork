import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { BridgeClient } from "../../bridge/client.ts";
import type {
  HandoffSource,
  HandoffSessions,
  InboxMessage,
  InboxTaskView,
  TaskSummary,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";
import { HandoffSessionPicker } from "./HandoffSessionPicker.tsx";
import {
  matchingDrafts,
  type HandoffDraft,
  type MessageReference,
} from "./handoff-drafts.ts";

type Actions = {
  client: Pick<BridgeClient, "handoffSessions" | "changeHandoff">;
  account: string | null;
  binding: string;
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  drafts: HandoffDraft[];
  onVerify(source: HandoffSource, storeId: string, title: string): void;
  onResume(draft: HandoffDraft, reference?: MessageReference): void;
  onCreate(
    source: HandoffSource,
    store: string,
    task: InboxTaskView,
    reference?: MessageReference,
  ): void;
  onOpen(taskId: string, reference?: MessageReference): void;
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

type ControlsProps = {
  referenced: string;
  remoteTask?: InboxTaskView;
  message?: InboxMessage;
  children?: ReactNode;
};

export function HandoffControls(props: ControlsProps) {
  const api = useContext(Context);
  return (
    <HandoffView
      key={JSON.stringify([
        api?.binding,
        api?.account,
        props.referenced,
        props.remoteTask?.id,
      ])}
      {...props}
    />
  );
}

function HandoffView({
  referenced,
  remoteTask,
  message,
  children,
}: ControlsProps) {
  const canonical = remoteTask?.id;
  const title = remoteTask?.name;
  const api = useContext(Context);
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(false);
  const [picking, setPicking] = useState(false);
  const moreTrigger = useRef<HTMLButtonElement>(null);
  const focusOnReturn = useRef(false);
  const mounted = useRef(false);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useLayoutEffect(() => {
    if (!picking && focusOnReturn.current && moreTrigger.current) {
      focusOnReturn.current = false;
      moreTrigger.current.focus();
    }
  });
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const list = api?.lists[referenced];
  const onVerify = api?.onVerify;
  const account = api?.account;
  const binding = api?.binding;
  useEffect(() => {
    if (
      onVerify &&
      account &&
      binding &&
      canonical &&
      title !== undefined &&
      list
    )
      onVerify(
        { binding, account, referenced, canonical },
        list.storeId,
        title,
      );
  }, [onVerify, account, binding, referenced, canonical, title, list]);
  const reading = children && (
    <div className="inbox-task-reading" hidden={picking}>
      {children}
    </div>
  );
  if (!api || (children && !canonical)) return reading;
  if (!list || !api.account)
    return canonical ? (
      <>
        {reading}
        <p role="status">
          {t(
            list === null || !api.account
              ? "handoff.unavailable"
              : "handoff.loading",
          )}
        </p>
        {picking && (
          <Button size="sm" variant="ghost" onClick={() => setPicking(false)}>
            {t("inbox.detail_back")}
          </Button>
        )}
      </>
    ) : null;
  const source = {
    binding: api.binding,
    account: api.account,
    referenced,
    canonical: canonical ?? referenced,
  };
  const reference = message
    ? { message, taskId: source.canonical, title }
    : undefined;
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
  async function mutate(action: "link" | "prefer" | "unlink", id: string) {
    if (!api || !list || !canonical || busy) return;
    setBusy(true);
    setFailed(false);
    try {
      await api.client.changeHandoff(source, list.storeId, action, id);
      api.refresh();
      if (action === "link" && mounted.current) api.onOpen(id, reference);
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  }
  if (!canonical && !sessions.length && !drafts.length) return null;
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
  if (canonical && remoteTask) {
    if (picking) {
      const linked = new Set(
        Object.values(api.lists).flatMap(
          (entry) => entry?.sessions.map((s) => s.taskId) ?? [],
        ),
      );
      const eligible = api.tasks.filter(
        (task) =>
          !task.archived &&
          !task.historyReadOnly &&
          task.lifecycle === "open" &&
          task.deletionStatus === "idle" &&
          !linked.has(task.id),
      );
      return (
        <>
          {reading}
          <HandoffSessionPicker
            taskNumber={canonical}
            tasks={eligible}
            workspaces={api.workspaces}
            busy={busy}
            failed={failed}
            onBack={() => {
              focusOnReturn.current = true;
              setPicking(false);
              if (failed) api.refresh();
              setFailed(false);
            }}
            onConfirm={(id) => void mutate("link", id)}
          />
        </>
      );
    }
    const openPicker = () => {
      setFailed(false);
      setPicking(true);
    };
    const create = () =>
      api.onCreate(source, list.storeId, remoteTask, reference);
    const current =
      active.find((s) => s.preferred) ??
      (active.length === 1 ? active[0] : undefined);
    const choose =
      !current &&
      (drafts.length > 1 || (!drafts.length && sessions.length > 1));
    const resume = !current && drafts.length === 1 ? drafts[0] : undefined;
    const history =
      !current && !drafts.length && sessions.length === 1
        ? sessions[0]
        : undefined;
    const destination = current ?? history;
    const newIsPrimary = !destination && !drafts.length && !sessions.length;
    return (
      <>
        {reading}
        <div className="handoff-toolbar">
          {!choose && (
            <Button
              className="handoff-primary"
              size="sm"
              disabled={busy}
              onClick={() => {
                if (destination) api.onOpen(destination.task.id, reference);
                else if (resume) api.onResume(resume, reference);
                else create();
              }}
            >
              <span>
                {destination
                  ? label(destination)
                  : t(resume ? "handoff.resume" : "handoff.new")}
              </span>
            </Button>
          )}
          <Menu.Root>
            <Menu.Trigger
              ref={moreTrigger}
              disabled={busy}
              render={
                <Button
                  size="sm"
                  className={choose ? "handoff-primary" : undefined}
                  variant={choose ? "primary" : "ghost"}
                />
              }
            >
              {t(choose ? "handoff.choose" : "handoff.other")}
              <Icon name="chevron" />
            </Menu.Trigger>
            <Menu.Portal>
              <Menu.Positioner align="end">
                <Menu.Popup className="handoff-menu">
                  <Menu.Item onClick={openPicker}>
                    {t("handoff.link")}…
                  </Menu.Item>
                  {!newIsPrimary && (
                    <Menu.Item onClick={create}>
                      {t("handoff.another")}
                    </Menu.Item>
                  )}
                  {drafts
                    .filter((d) => d !== resume)
                    .map((draft) => (
                      <Menu.Item
                        key={draft.operationId}
                        onClick={() => api.onResume(draft, reference)}
                      >
                        {t("handoff.resume")}
                        {drafts.length > 1 && " " + (drafts.indexOf(draft) + 1)}
                      </Menu.Item>
                    ))}
                  {sessions.map((s) => (
                    <Menu.Group key={s.task.id}>
                      <Menu.Separator />
                      <Menu.GroupLabel>
                        {s.task.title}
                        {s.preferred &&
                          sessions.length > 1 &&
                          " · " + t("handoff.default")}
                      </Menu.GroupLabel>
                      {s !== destination && (
                        <Menu.Item
                          onClick={() => api.onOpen(s.task.id, reference)}
                        >
                          {label(s)}
                        </Menu.Item>
                      )}
                      {!s.preferred && !s.task.archived && (
                        <Menu.Item
                          onClick={() => void mutate("prefer", s.task.id)}
                        >
                          {t("handoff.prefer")}
                        </Menu.Item>
                      )}
                      <Menu.Item
                        onClick={() => void mutate("unlink", s.task.id)}
                      >
                        {t("handoff.unlink")}
                      </Menu.Item>
                    </Menu.Group>
                  ))}
                </Menu.Popup>
              </Menu.Positioner>
            </Menu.Portal>
          </Menu.Root>
        </div>
        {failed && <p role="alert">{t("handoff.change_failed")}</p>}
      </>
    );
  }
  return (
    <div className="inbox-handoff">
      {(sessions.length > 1 || drafts.length > 1) && (
        <Button
          size="sm"
          variant="ghost"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {t("handoff.choose")} ({sessions.length + drafts.length})
        </Button>
      )}
      {!expanded && primary && (
        <Button
          size="sm"
          variant="ghost"
          onClick={() => api.onOpen(primary.task.id, reference)}
        >
          {label(primary)}
        </Button>
      )}
      {expanded &&
        sessions.map((s) => (
          <div className="inbox-handoff-row" key={s.task.id}>
            <Button
              size="sm"
              variant="ghost"
              title={s.workspace?.canonicalRoot}
              onClick={() => api.onOpen(s.task.id, reference)}
            >
              {label(s)}
              {s.preferred && sessions.length > 1
                ? " · " + t("handoff.default")
                : ""}
            </Button>
          </div>
        ))}
      {(expanded || drafts.length === 1) &&
        drafts.map((draft, i) => (
          <Button
            size="sm"
            variant="ghost"
            key={draft.operationId}
            onClick={() => api.onResume(draft, reference)}
          >
            {t("handoff.resume")}
            {drafts.length > 1 ? " " + (i + 1) : ""}
          </Button>
        ))}
    </div>
  );
}
