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
import { matchingDrafts, type HandoffDraft } from "./handoff-drafts.ts";

type Actions = {
  client: Pick<BridgeClient, "handoffSessions" | "changeHandoff">;
  account: string | null;
  binding: string;
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  drafts: HandoffDraft[];
  onVerify(source: HandoffSource, storeId: string, title: string): void;
  onResume(draft: HandoffDraft): void;
  onCreate(
    source: HandoffSource,
    store: string,
    task: InboxTaskView,
    message?: InboxMessage,
  ): void;
  onOpen(taskId: string): void;
};
const Context = createContext<
  | (Actions & {
      lists: Record<string, HandoffSessions | null>;
      refresh(): void;
    })
  | null
>(null);

export type AttachmentSummary = {
  kind: "task" | "file" | "project";
  id: string;
  name: string;
};

const attachmentIcons = {
  task: "task-list",
  file: "skill-file",
  project: "workspace",
  unknown: "paperclip",
} as const;

function useHandoffTargets(referenced: string, canonical = referenced) {
  const api = useContext(Context);
  const list = api?.lists[referenced];
  const sessions = (list?.sessions ?? []).flatMap((link) => {
    const task = api?.tasks.find((item) => item.id === link.taskId);
    return task
      ? [
          {
            task,
            preferred: link.preferred,
            workspace: api?.workspaces.find((w) => w.id === task.workspaceId),
          },
        ]
      : [];
  });
  const drafts =
    api?.account && list
      ? matchingDrafts(
          api.drafts,
          api.account,
          list.storeId,
          referenced,
          canonical,
        )
      : [];
  return { api, list, sessions, drafts };
}

type LinkedSession = ReturnType<typeof useHandoffTargets>["sessions"][number];

function availableSession(s: LinkedSession) {
  return (
    !s.task.archived &&
    !s.task.historyReadOnly &&
    s.task.lifecycle === "open" &&
    s.task.deletionStatus === "idle"
  );
}

function sessionAction(s: LinkedSession) {
  if (s.task.archived || s.task.historyReadOnly) return "handoff.history";
  return s.workspace?.authorization === "available"
    ? "handoff.continue"
    : "handoff.reauthorize";
}

export function MessageAttachment({
  id,
  summary,
  onOpen,
}: {
  id: string;
  summary?: AttachmentSummary | null;
  onOpen(): void;
}) {
  const { t } = useI18n();
  const { api, sessions, drafts } = useHandoffTargets(id, summary?.id);
  const canOfferSessions = !summary || summary.kind === "task";
  const count = canOfferSessions ? sessions.length + drafts.length : 0;
  const draftSummary =
    summary === undefined
      ? (drafts.find((draft) => draft.title) ?? drafts[0])
      : undefined;
  const kind =
    summary?.kind ?? (summary === undefined && count ? "task" : "unknown");
  const title = summary?.name ?? draftSummary?.title;
  const number = summary?.id ?? draftSummary?.source.canonical ?? id;
  const caption = t(`inbox.attachment_${kind}`, { id: number });
  const direct =
    sessions.find((s) => s.preferred && availableSession(s)) ??
    (count === 1 ? sessions[0] : undefined);
  return (
    <div className="inbox-attachment">
      <button
        type="button"
        className="inbox-linked-item"
        onClick={onOpen}
        aria-haspopup="dialog"
        aria-label={title ? `${title} ${caption}` : caption}
        title={title}
      >
        <Icon name={attachmentIcons[kind]} />
        <span>{title || caption}</span>
      </button>
      {title && <span className="inbox-attachment-id">{caption}</span>}
      {api &&
        count > 0 &&
        (direct || count === 1 ? (
          <button
            type="button"
            className="inbox-attachment-action"
            onClick={() =>
              direct ? api.onOpen(direct.task.id) : api.onResume(drafts[0])
            }
          >
            {t(direct ? sessionAction(direct) : "handoff.resume")}
            <Icon name="chevron-right" />
          </button>
        ) : (
          <Menu.Root>
            <Menu.Trigger className="inbox-attachment-action">
              {t("handoff.choose_session")}
              <Icon name="chevron" />
            </Menu.Trigger>
            <Menu.Portal>
              <Menu.Positioner align="end">
                <Menu.Popup className="handoff-menu">
                  {sessions.map((s) => (
                    <Menu.Item
                      key={s.task.id}
                      onClick={() => api.onOpen(s.task.id)}
                    >
                      {t(sessionAction(s))} · {s.task.title}
                    </Menu.Item>
                  ))}
                  {drafts.map((d, i) => (
                    <Menu.Item
                      key={d.operationId}
                      onClick={() => api.onResume(d)}
                    >
                      {t("handoff.resume")}
                      {drafts.length > 1 && ` ${i + 1}`}
                    </Menu.Item>
                  ))}
                </Menu.Popup>
              </Menu.Positioner>
            </Menu.Portal>
          </Menu.Root>
        ))}
    </div>
  );
}

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
  children: ReactNode;
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
  const { api, list, sessions, drafts } = useHandoffTargets(
    referenced,
    canonical,
  );
  const { t } = useI18n();
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
  if (!api) return reading;
  if (remoteTask && canonical) {
    if (!list || !api.account)
      return (
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
      );
    const source = {
      binding: api.binding,
      account: api.account,
      referenced,
      canonical,
    };
    const active = sessions.filter(availableSession);
    async function mutate(action: "link" | "prefer" | "unlink", id: string) {
      if (!api || !list || !canonical || busy) return;
      setBusy(true);
      setFailed(false);
      try {
        await api.client.changeHandoff(source, list.storeId, action, id);
        api.refresh();
        if (action === "link" && mounted.current) api.onOpen(id);
      } catch {
        setFailed(true);
      } finally {
        setBusy(false);
      }
    }
    function label(s: (typeof sessions)[number]) {
      return t(sessionAction(s)) + " · " + s.task.title;
    }
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
      api.onCreate(source, list.storeId, remoteTask, message);
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
                if (destination) api.onOpen(destination.task.id);
                else if (resume) api.onResume(resume);
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
                        onClick={() => api.onResume(draft)}
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
                        <Menu.Item onClick={() => api.onOpen(s.task.id)}>
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
  return reading;
}
