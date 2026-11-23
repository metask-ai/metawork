import {
  type ReactNode,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";

import type { BridgeClient } from "../../bridge/client.ts";
import type {
  InboxConversation,
  InboxMessage,
  InboxTaskDetail,
  InboxView,
} from "../../bridge/contracts.ts";
import { Badge } from "../../components/ui/badge.tsx";
import { Button } from "../../components/ui/button.tsx";
import { DiagnosticDisclosure } from "../../components/ui/DiagnosticDisclosure.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";
import { inboxDiagnosticText } from "./inbox-diagnostics.ts";

/** While the inbox page is open and visible the Host is asked this often. */
export const inboxRefreshMs = 15_000;

export type InboxClient = Pick<
  BridgeClient,
  | "refreshInbox"
  | "loadEarlierInbox"
  | "readInboxConversation"
  | "readInboxTask"
>;

/** One read's own outcome; the connection state stays the list's. */
type ConversationFailure = "forbidden" | "not_found" | "failed" | "unavailable";

export type OpenedConversation = {
  peerId: string;
  name: string;
  messages: readonly InboxMessage[];
  hasEarlier: boolean;
  loading: boolean;
  failure: ConversationFailure | null;
};

export type OpenedTask = {
  taskId: string;
  status: "loading" | "ready" | "forbidden" | "not_found" | "failed";
  task: InboxTaskDetail["task"];
};

function mergeMessages(
  older: readonly InboxMessage[],
  newer: readonly InboxMessage[],
) {
  const seen = new Set(newer.map((message) => message.id));
  return [...older.filter((message) => !seen.has(message.id)), ...newer];
}

/** MetaTeam's conversation of what the user sent to themself. */
export const selfPeerId = "me";

function conversationName(
  peerId: string,
  name: string,
  t: ReturnType<typeof useI18n>["t"],
) {
  return peerId === selfPeerId ? t("inbox.self_conversation") : name;
}

function countLabel(value: string) {
  const count = Number(value);
  return count > 99 ? "99+" : String(count);
}

/**
 * The inbox page state shared by the conversation list and the reading area.
 * The Host owns the conversation list; this keeps only what is on screen:
 * the selected member, that conversation's loaded messages and an open task.
 */
export function useInbox(
  client: InboxClient,
  inbox: InboxView,
  open: boolean,
  disabled: boolean,
) {
  const binding = inbox.binding;
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [conversation, setConversation] = useState<OpenedConversation | null>(
    null,
  );
  const [task, setTask] = useState<OpenedTask | null>(null);
  const readRef = useRef<
    (
      peerId: string,
      page: "latest" | "before" | "after",
      anchor: string | null,
    ) => Promise<void>
  >(async () => {});
  const followed = useRef<string | null>(null);

  // A different MetaTeam connection is a different inbox.
  useEffect(() => {
    setSelectedId(null);
    setConversation(null);
    setTask(null);
    followed.current = null;
  }, [binding]);

  useEffect(() => {
    if (!open || disabled) return;
    // An automatic refresh: the Host skips it in the background, while
    // refused and before a failure's retry delay.
    const tick = () => {
      if (document.visibilityState !== "visible") return;
      void client.refreshInbox(binding, false).catch(() => undefined);
    };
    tick();
    const timer = window.setInterval(tick, inboxRefreshMs);
    document.addEventListener("visibilitychange", tick);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", tick);
    };
  }, [client, binding, open, disabled]);

  const read = useCallback(
    async (
      peerId: string,
      page: "latest" | "before" | "after",
      anchor: string | null,
    ) => {
      setConversation((current) =>
        current?.peerId === peerId
          ? { ...current, loading: true }
          : {
              peerId,
              name: peerId,
              messages: [],
              hasEarlier: false,
              loading: true,
              failure: null,
            },
      );
      let result: Awaited<
        ReturnType<InboxClient["readInboxConversation"]>
      > | null = null;
      try {
        result = await client.readInboxConversation(
          binding,
          peerId,
          page,
          anchor,
        );
      } catch {
        result = null;
      }
      const answer = result;
      setConversation((current) => {
        if (current?.peerId !== peerId) return current;
        if (answer === null)
          return { ...current, loading: false, failure: "failed" };
        switch (answer.state) {
          case "superseded":
          case "stale_binding":
            return current;
          case "ready":
            if (page === "latest")
              return {
                ...current,
                messages: answer.messages,
                hasEarlier: answer.hasEarlier,
                loading: false,
                failure: null,
              };
            if (page === "before")
              return {
                ...current,
                messages: mergeMessages(answer.messages, current.messages),
                hasEarlier: answer.hasEarlier,
                loading: false,
                failure: null,
              };
            return {
              ...current,
              messages: mergeMessages(current.messages, answer.messages),
              loading: false,
              failure: null,
            };
          case "unknown_peer":
            return { ...current, loading: false, failure: "unavailable" };
          default:
            return { ...current, loading: false, failure: answer.state };
        }
      });
      // Newer messages that did not all fit: read the latest page instead of
      // guessing what lies in between.
      if (answer?.state === "ready" && page === "after" && !answer.complete)
        await readRef.current(peerId, "latest", null);
    },
    [client, binding],
  );
  readRef.current = read;

  // Follow new messages of the open conversation while it is shown.
  const summary = inbox.conversations.find(
    (item) => item.peerId === conversation?.peerId,
  );
  const latestId = summary?.latest?.id ?? null;
  useEffect(() => {
    if (!open || !conversation || conversation.loading) return;
    if (conversation.failure || latestId === null) return;
    const last = conversation.messages.at(-1);
    if (!last || conversation.messages.some((item) => item.id === latestId))
      return;
    if (followed.current === latestId) return;
    followed.current = latestId;
    void read(conversation.peerId, "after", last.id);
  }, [open, conversation, latestId, read]);

  return {
    selectedId,
    conversation,
    task,
    select(peerId: string, name: string) {
      setSelectedId(peerId);
      setTask(null);
      followed.current = null;
      setConversation({
        peerId,
        name,
        messages: [],
        hasEarlier: false,
        loading: true,
        failure: null,
      });
      void read(peerId, "latest", null);
    },
    loadEarlierMessages() {
      const first = conversation?.messages[0];
      if (!conversation || !first || conversation.loading) return;
      void read(conversation.peerId, "before", first.id);
    },
    loadEarlierConversations() {
      void client.loadEarlierInbox(binding).catch(() => undefined);
    },
    /** The user's own retry: past any retry delay or refusal. */
    retry() {
      void client.refreshInbox(binding, true).catch(() => undefined);
      if (conversation?.failure) void read(conversation.peerId, "latest", null);
    },
    async openTask(taskId: string) {
      setTask({ taskId, status: "loading", task: null });
      let detail: InboxTaskDetail | null = null;
      try {
        detail = await client.readInboxTask(binding, taskId);
      } catch {
        detail = null;
      }
      setTask((current) => {
        if (current?.taskId !== taskId) return current;
        if (detail?.state === "superseded") return current;
        if (detail?.state === "ready")
          return { taskId, status: "ready", task: detail.task };
        const status =
          detail?.state === "forbidden" || detail?.state === "not_found"
            ? detail.state
            : "failed";
        return { taskId, status, task: null };
      });
    },
    closeTask() {
      setTask(null);
    },
  };
}

export type InboxController = ReturnType<typeof useInbox>;

/** The unread total the navigation shows, when there is a usable one. */
export function inboxUnread(inbox: InboxView) {
  if (inbox.unreadTotal === null) return 0;
  return Number(inbox.unreadTotal);
}

export function MessageNavigationItem({
  active,
  unread,
  onOpen,
}: {
  active: boolean;
  unread: number;
  onOpen: () => void;
}) {
  const { t } = useI18n();
  return (
    <Tooltip.Root>
      <Tooltip.Trigger
        type="button"
        className="primary-navigation-item focus-ring"
        aria-label={
          unread > 0
            ? t("inbox.title_unread", { count: unread })
            : t("inbox.title")
        }
        aria-current={active ? "page" : undefined}
        onClick={onOpen}
      >
        <Icon name="messages" />
        {unread > 0 && (
          <span
            className="inbox-unread-badge primary-navigation-unread"
            aria-hidden="true"
          >
            {countLabel(String(unread))}
          </span>
        )}
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Positioner side="right">
          <Tooltip.Popup>{t("inbox.title")}</Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

function InboxAvatar({ name }: { name: string }) {
  return (
    <span className="inbox-avatar" aria-hidden="true">
      {Array.from(name)[0]}
    </span>
  );
}

function useTimeFormats() {
  const { locale } = useI18n();
  const language = locale === "zh-CN" ? "zh-CN" : "en-US";
  return {
    time: new Intl.DateTimeFormat(language, {
      hour: "numeric",
      minute: "2-digit",
    }),
    day: new Intl.DateTimeFormat(language, {
      month: "numeric",
      day: "numeric",
    }),
    date: new Intl.DateTimeFormat(language, { dateStyle: "medium" }),
    dateTime: new Intl.DateTimeFormat(language, {
      dateStyle: "medium",
      timeStyle: "short",
    }),
  };
}

function ConversationRow({
  conversation,
  selected,
  onSelect,
}: {
  conversation: InboxConversation;
  selected: boolean;
  onSelect: () => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  const unread = Number(conversation.unread);
  const latest = conversation.latest;
  const name = conversationName(conversation.peerId, conversation.name, t);
  const sentAt = latest ? new Date(Number(latest.sentAtMs)) : null;
  const today = new Date().toDateString();
  const preview = latest
    ? latest.direction !== "in"
      ? t("inbox.preview_self", { text: latest.preview })
      : latest.preview
    : "";
  return (
    <li>
      <button
        type="button"
        className="inbox-list-row focus-ring"
        aria-label={
          unread > 0
            ? t("inbox.conversation_unread", {
                name,
                count: unread,
              })
            : name
        }
        aria-current={selected ? "true" : undefined}
        data-unread={unread > 0}
        onClick={onSelect}
      >
        <InboxAvatar name={name} />
        <span className="inbox-row-copy">
          <strong>{name}</strong>
          <span>{preview}</span>
        </span>
        <span className="inbox-row-meta">
          {sentAt && (
            <time
              dateTime={sentAt.toISOString()}
              title={formats.dateTime.format(sentAt)}
            >
              {today === sentAt.toDateString()
                ? formats.time.format(sentAt)
                : formats.day.format(sentAt)}
            </time>
          )}
          {unread > 0 && (
            <span className="inbox-unread-badge" aria-hidden="true">
              {countLabel(conversation.unread)}
            </span>
          )}
        </span>
      </button>
    </li>
  );
}

function EarlierConversations({
  loading,
  automatic,
  onLoad,
}: {
  loading: boolean;
  /** Whether reaching the end may ask by itself. */
  automatic: boolean;
  onLoad: () => void;
}) {
  const { t } = useI18n();
  const footer = useRef<HTMLDivElement>(null);
  const load = useRef(onLoad);
  load.current = onLoad;
  // Scrolling to the end of the list asks for the next page by itself.
  useEffect(() => {
    const node = footer.current;
    if (
      !node ||
      loading ||
      !automatic ||
      typeof IntersectionObserver === "undefined"
    )
      return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) load.current();
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [loading, automatic]);
  return (
    <div className="inbox-list-footer" ref={footer}>
      <Button
        type="button"
        size="sm"
        variant="ghost"
        disabled={loading}
        onClick={onLoad}
      >
        {loading
          ? t("inbox.loading_conversations")
          : t("inbox.load_earlier_conversations")}
      </Button>
    </div>
  );
}

export function InboxSidebar({
  inbox,
  controller,
  onSelected,
}: {
  inbox: InboxView;
  controller: InboxController;
  /** A narrow window closes the conversation drawer once one is chosen. */
  onSelected?: () => void;
}) {
  const { t } = useI18n();
  const usable = inbox.state === "ready" || inbox.state === "unreachable";
  const empty = inbox.conversations.length === 0;
  // A page of history can belong to a single busy sender and add no new
  // conversation, so the end of the list stays in view. Asking by itself
  // stops after such a page instead of walking the whole history; the
  // button still asks for more.
  const [automatic, setAutomatic] = useState(true);
  const countAtRequest = useRef<number | null>(null);
  const count = inbox.conversations.length;
  useEffect(() => {
    setAutomatic(true);
    countAtRequest.current = null;
  }, [inbox.binding]);
  useEffect(() => {
    if (inbox.loadingConversations) return;
    if (countAtRequest.current !== null && count <= countAtRequest.current)
      setAutomatic(false);
    countAtRequest.current = null;
  }, [inbox.loadingConversations, count]);
  const loadEarlier = () => {
    countAtRequest.current = count;
    controller.loadEarlierConversations();
  };
  return (
    <section className="inbox-list" aria-labelledby="inbox-list-title">
      <h2 id="inbox-list-title">{t("inbox.title")}</h2>
      {!empty && (
        <ul className="inbox-list-scroll">
          {inbox.conversations.map((conversation) => (
            <ConversationRow
              key={conversation.peerId}
              conversation={conversation}
              selected={controller.selectedId === conversation.peerId}
              onSelect={() => {
                controller.select(
                  conversation.peerId,
                  conversationName(conversation.peerId, conversation.name, t),
                );
                onSelected?.();
              }}
            />
          ))}
          {inbox.hasEarlier && (
            <li>
              <EarlierConversations
                loading={inbox.loadingConversations}
                automatic={automatic}
                onLoad={loadEarlier}
              />
            </li>
          )}
        </ul>
      )}
      {empty && usable && (
        <p className="inbox-list-note">
          {inbox.conversationsLoaded
            ? t("inbox.no_conversations")
            : t("inbox.loading_conversations")}
        </p>
      )}
    </section>
  );
}

function InboxNotice({
  title,
  hint,
  children,
}: {
  title: string;
  hint?: string;
  children?: ReactNode;
}) {
  return (
    <div className="inbox-empty">
      <span className="inbox-empty-icon" aria-hidden="true">
        <Icon name="messages" />
      </span>
      <h1>{title}</h1>
      {hint && <p>{hint}</p>}
      {children && <div className="inbox-notice-actions">{children}</div>}
    </div>
  );
}

function LinkedTask({
  taskId,
  onOpen,
}: {
  taskId: string;
  onOpen: () => void;
}) {
  const { t } = useI18n();
  return (
    <button type="button" className="inbox-task-card" onClick={onOpen}>
      <span className="inbox-task-icon">
        <Icon name="new-task" />
      </span>
      <span className="inbox-task-caption">
        <span>{t("inbox.linked_task")}</span>
        <strong>{t("inbox.task_number", { id: taskId })}</strong>
      </span>
      <span className="inbox-task-end">
        <Icon name="chevron-right" />
      </span>
    </button>
  );
}

function InboxTaskDialog({
  task,
  onClose,
}: {
  task: OpenedTask | null;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  const detail = task?.task ?? null;
  return (
    <Dialog.Root
      open={task !== null}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup>
          <div className="inbox-task-dialog-header">
            <span className="inbox-task-icon">
              <Icon name="new-task" />
            </span>
            <Dialog.Title>
              {detail?.name ??
                (task ? t("inbox.task_number", { id: task.taskId }) : "")}
            </Dialog.Title>
            <Dialog.Close
              className="icon-button"
              aria-label={t("common.close")}
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          {task?.status === "loading" && (
            <Dialog.Description className="inbox-task-description">
              {t("inbox.task_loading")}
            </Dialog.Description>
          )}
          {(task?.status === "failed" ||
            task?.status === "forbidden" ||
            task?.status === "not_found") && (
            <Dialog.Description className="inbox-task-description">
              {task.status === "forbidden"
                ? t("inbox.task_forbidden")
                : task.status === "not_found"
                  ? t("inbox.task_not_found")
                  : t("inbox.task_failed")}
            </Dialog.Description>
          )}
          {detail && (
            <>
              {detail.description && (
                <Dialog.Description className="inbox-task-description">
                  {detail.description}
                </Dialog.Description>
              )}
              <dl className="inbox-task-facts">
                <div>
                  <dt>{t("inbox.task_id")}</dt>
                  <dd>{detail.id}</dd>
                </div>
                {(detail.progress ?? detail.state) && (
                  <div>
                    <dt>{t("inbox.task_status")}</dt>
                    <dd>
                      <Badge className="whitespace-nowrap">
                        {detail.progress ?? detail.state}
                      </Badge>
                    </dd>
                  </div>
                )}
                {detail.assignees.length > 0 && (
                  <div>
                    <dt>{t("inbox.task_assignees")}</dt>
                    <dd>{detail.assignees.join(t("inbox.list_separator"))}</dd>
                  </div>
                )}
                {detail.path && (
                  <div>
                    <dt>{t("inbox.task_path")}</dt>
                    <dd>{detail.path}</dd>
                  </div>
                )}
                {detail.updatedAtMs && (
                  <div>
                    <dt>{t("inbox.task_updated")}</dt>
                    <dd>
                      {formats.dateTime.format(
                        new Date(Number(detail.updatedAtMs)),
                      )}
                    </dd>
                  </div>
                )}
              </dl>
            </>
          )}
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function InboxConversationView({
  name,
  conversation,
  onLoadEarlier,
  onOpenTask,
  onRetry,
}: {
  name: string;
  conversation: OpenedConversation;
  onLoadEarlier: () => void;
  onOpenTask: (taskId: string) => void;
  onRetry: () => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  const transcript = useRef<HTMLDivElement>(null);
  const lastId = conversation.messages.at(-1)?.id;
  // Keep the newest message in view as the conversation opens or grows.
  useLayoutEffect(() => {
    const scroll = transcript.current;
    if (scroll) scroll.scrollTop = scroll.scrollHeight;
  }, [conversation.peerId, lastId]);
  return (
    <section
      key={conversation.peerId}
      className="inbox-detail"
      aria-labelledby="inbox-conversation-title"
      aria-busy={conversation.loading || undefined}
    >
      <header className="inbox-detail-header">
        <InboxAvatar name={name} />
        <h1 id="inbox-conversation-title">{name}</h1>
      </header>
      <div className="inbox-transcript-scroll" ref={transcript}>
        {conversation.failure && (
          <div className="inbox-banner" role="status">
            <span>
              {conversation.failure === "forbidden"
                ? t("inbox.conversation_forbidden")
                : conversation.failure === "not_found"
                  ? t("inbox.conversation_not_found")
                  : t("inbox.conversation_failed")}
            </span>
            <Button type="button" size="sm" variant="ghost" onClick={onRetry}>
              {t("inbox.retry")}
            </Button>
          </div>
        )}
        {conversation.hasEarlier && (
          <div className="inbox-transcript-earlier">
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={conversation.loading}
              onClick={onLoadEarlier}
            >
              {t("inbox.load_earlier_messages")}
            </Button>
          </div>
        )}
        {conversation.loading && conversation.messages.length === 0 && (
          <p className="inbox-list-note">{t("inbox.loading_messages")}</p>
        )}
        <ol className="inbox-transcript">
          {conversation.messages.map((message, index) => {
            const sentAt = new Date(Number(message.sentAtMs));
            const previous = conversation.messages[index - 1];
            const startsDay =
              !previous ||
              sentAt.toDateString() !==
                new Date(Number(previous.sentAtMs)).toDateString();
            // What the user sent, to others or to themself.
            const outgoing = message.direction !== "in";
            const others = message.recipients.filter(
              (recipient) =>
                recipient.peerId !== conversation.peerId &&
                recipient.peerId !== message.fromPeerId,
            );
            return (
              <li className="inbox-transcript-entry" key={message.id}>
                {startsDay && (
                  <div className="inbox-transcript-date">
                    <time dateTime={sentAt.toISOString()}>
                      {formats.date.format(sentAt)}
                    </time>
                  </div>
                )}
                <div
                  className="inbox-message"
                  data-direction={outgoing ? "outgoing" : "incoming"}
                  data-linked-task={message.taskIds.length > 0}
                >
                  <div className="inbox-message-meta">
                    <span>
                      {outgoing ? t("inbox.sender_self") : message.fromName}
                    </span>
                    <time dateTime={sentAt.toISOString()}>
                      {formats.time.format(sentAt)}
                    </time>
                  </div>
                  {outgoing && others.length > 0 && (
                    <div className="inbox-message-recipients">
                      {t("inbox.also_sent_to", {
                        names: others
                          .map((recipient) => recipient.name)
                          .join(t("inbox.list_separator")),
                      })}
                    </div>
                  )}
                  <div className="inbox-bubble">
                    <p>{message.text}</p>
                  </div>
                  {message.truncated && (
                    <p className="inbox-message-note">
                      {t("inbox.message_truncated")}
                    </p>
                  )}
                  {message.taskIds.map((taskId) => (
                    <LinkedTask
                      key={taskId}
                      taskId={taskId}
                      onOpen={() => onOpenTask(taskId)}
                    />
                  ))}
                </div>
              </li>
            );
          })}
        </ol>
      </div>
    </section>
  );
}

/**
 * The reading area: the connection state when there is nothing to read,
 * otherwise the selected conversation. Read only: there is no reply box.
 */
export function InboxMain({
  inbox,
  controller,
  onOpenConnectors,
}: {
  inbox: InboxView;
  controller: InboxController;
  onOpenConnectors: () => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  const retry = (
    <Button type="button" size="md" onClick={controller.retry}>
      {t("inbox.retry")}
    </Button>
  );
  const connectors = (
    <Button
      type="button"
      size="md"
      variant="secondary"
      onClick={onOpenConnectors}
    >
      {t("inbox.open_connectors")}
    </Button>
  );
  const diagnostic = inbox.diagnostic && (
    <DiagnosticDisclosure label={t("inbox.diagnostics")}>
      <pre className="feedback-notice-details">
        {inboxDiagnosticText(inbox.diagnostic, t)}
      </pre>
    </DiagnosticDisclosure>
  );
  if (inbox.state === "unavailable")
    return (
      <InboxNotice
        title={t("inbox.unavailable")}
        hint={t("inbox.unavailable_hint")}
      >
        {connectors}
      </InboxNotice>
    );
  if (inbox.state === "checking")
    return <InboxNotice title={t("inbox.checking")} />;
  if (inbox.state === "reauthorize")
    return (
      <InboxNotice
        title={t("inbox.reauthorize")}
        hint={t("inbox.reauthorize_hint")}
      >
        {retry}
        {connectors}
      </InboxNotice>
    );
  const stale = inbox.state === "unreachable";
  if (stale && inbox.unreadTotal === null && inbox.conversations.length === 0)
    return (
      <InboxNotice title={t("inbox.unreachable")}>
        {retry}
        {diagnostic}
      </InboxNotice>
    );
  return (
    <>
      {stale && (
        <div className="inbox-banner" role="status">
          <span>
            {inbox.syncedAtMs
              ? t("inbox.unreachable_stale", {
                  time: formats.dateTime.format(
                    new Date(Number(inbox.syncedAtMs)),
                  ),
                })
              : t("inbox.unreachable")}
          </span>
          <Button
            type="button"
            size="sm"
            variant="ghost"
            onClick={controller.retry}
          >
            {t("inbox.retry")}
          </Button>
          {diagnostic}
        </div>
      )}
      {controller.conversation ? (
        <InboxConversationView
          name={controller.conversation.name}
          conversation={controller.conversation}
          onLoadEarlier={controller.loadEarlierMessages}
          onOpenTask={(taskId) => void controller.openTask(taskId)}
          onRetry={controller.retry}
        />
      ) : (
        <InboxNotice
          title={t("inbox.pick_conversation")}
          hint={t("inbox.pick_hint")}
        />
      )}
      <InboxTaskDialog task={controller.task} onClose={controller.closeTask} />
    </>
  );
}
