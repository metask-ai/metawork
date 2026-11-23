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
  InboxFileView,
  InboxMessage,
  InboxProjectView,
  InboxTaskDetail,
  InboxTaskView,
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
  | "openInboxFile"
  | "sendInboxMessage"
>;

/**
 * Why a message was not sent. `failed` may have reached MetaTeam: its retry
 * sends the same request again, which MetaTeam takes at most once. A
 * refusal (`rejected`, `forbidden`, `not_found`) is kept by MetaTeam for
 * that request, so only a changed message is sent again.
 */
export type SendFailure =
  | "failed"
  | "busy"
  | "unavailable"
  | "unknown_peer"
  | "rejected"
  | "forbidden"
  | "not_found";

/** The reply being written in the open conversation. */
export type Composer = {
  peerId: string;
  text: string;
  sending: boolean;
  failure: SendFailure | null;
  /** The identity of the last attempt, kept while its retry may reuse it. */
  requestKey: string | null;
};

export function sendRetryable(failure: SendFailure) {
  return (
    failure !== "rejected" && failure !== "forbidden" && failure !== "not_found"
  );
}

/** A random UUID; also where `crypto.randomUUID` is not offered. */
function newRequestKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function sendFailure(state: string): SendFailure {
  switch (state) {
    case "busy":
    case "unavailable":
    case "unknown_peer":
    case "rejected":
    case "forbidden":
    case "not_found":
      return state;
    default:
      // No answer, a server error, or an answer that never came back.
      return "failed";
  }
}

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

/** Opening a shared file's download, as the Host answered. */
export type DownloadStatus =
  | "idle"
  | "opening"
  | "opened"
  | "not_downloadable"
  | "forbidden"
  | "not_found"
  | "failed";

/**
 * The linked item open in the detail dialog: a task, a shared file or a
 * project. `trail` holds the items it was reached from, for going back.
 */
export type OpenedTask = {
  taskId: string;
  status: "loading" | "ready" | "forbidden" | "not_found" | "failed";
  detail: InboxTaskDetail | null;
  trail: readonly string[];
  download: DownloadStatus;
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
  const [composer, setComposer] = useState<Composer | null>(null);
  const conversationRef = useRef(conversation);
  conversationRef.current = conversation;
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
    setComposer(null);
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
    composer,
    /** A changed message is a new message: it gets a new identity. */
    setDraft(text: string) {
      setComposer((current) =>
        current === null || current.sending || current.text === text
          ? current
          : { ...current, text, failure: null, requestKey: null },
      );
    },
    async send() {
      const draft = composer;
      if (!draft || draft.sending || draft.text.trim() === "") return;
      const { peerId, text } = draft;
      const requestKey = draft.requestKey ?? newRequestKey();
      setComposer({ ...draft, sending: true, failure: null, requestKey });
      let state = "failed";
      try {
        state = (
          await client.sendInboxMessage(binding, peerId, text, requestKey)
        ).state;
      } catch {
        state = "failed";
      }
      if (state === "sent") {
        setComposer((current) =>
          current?.peerId === peerId
            ? {
                peerId,
                text: "",
                sending: false,
                failure: null,
                requestKey: null,
              }
            : current,
        );
        // Show it: what came after the newest message on screen.
        const open = conversationRef.current;
        if (open?.peerId === peerId) {
          const last = open.messages.at(-1);
          await read(peerId, last ? "after" : "latest", last?.id ?? null);
        }
        return;
      }
      const failure = sendFailure(state);
      setComposer((current) =>
        current?.peerId === peerId
          ? {
              ...current,
              sending: false,
              failure,
              requestKey: sendRetryable(failure) ? requestKey : null,
            }
          : current,
      );
    },
    select(peerId: string, name: string) {
      setSelectedId(peerId);
      setTask(null);
      // Opening the same conversation again keeps what was being written.
      setComposer((current) =>
        current?.peerId === peerId
          ? current
          : {
              peerId,
              text: "",
              sending: false,
              failure: null,
              requestKey: null,
            },
      );
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
    openTask,
    /** A sub-task or a project's file, opened from the item on screen. */
    openNested(taskId: string) {
      void openTask(taskId, task ? [...task.trail, task.taskId] : []);
    },
    back() {
      const previous = task?.trail.at(-1);
      if (task && previous !== undefined)
        void openTask(previous, task.trail.slice(0, -1));
    },
    async downloadFile(fileId: string) {
      setTask((current) =>
        current?.taskId === fileId
          ? { ...current, download: "opening" }
          : current,
      );
      let status: DownloadStatus = "failed";
      try {
        const result = await client.openInboxFile(binding, fileId);
        if (result.state === "superseded") return;
        status =
          result.state === "opened" ||
          result.state === "not_downloadable" ||
          result.state === "forbidden" ||
          result.state === "not_found"
            ? result.state
            : "failed";
      } catch {
        status = "failed";
      }
      setTask((current) =>
        current?.taskId === fileId ? { ...current, download: status } : current,
      );
    },
    closeTask() {
      setTask(null);
    },
  };

  async function openTask(taskId: string, trail: readonly string[] = []) {
    setTask({
      taskId,
      status: "loading",
      detail: null,
      trail,
      download: "idle",
    });
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
        return { ...current, status: "ready", detail };
      const status =
        detail?.state === "forbidden" || detail?.state === "not_found"
          ? detail.state
          : "failed";
      return { ...current, status, detail: null };
    });
  }
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
  // An unread member without a message in the list yet shows when their
  // latest unread message came.
  const shownAt = latest?.sentAtMs ?? conversation.lastAtMs;
  const sentAt = shownAt === null ? null : new Date(Number(shownAt));
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
        <span>{t("inbox.linked_item")}</span>
        <strong>{t("inbox.item_number", { id: taskId })}</strong>
      </span>
      <span className="inbox-task-end">
        <Icon name="chevron-right" />
      </span>
    </button>
  );
}

/** Sizes as the composer shows attachments: decimal units. */
function formatSize(value: string) {
  const bytes = Number(value);
  if (!Number.isSafeInteger(bytes) || bytes < 0) return value;
  if (bytes < 1_000) return `${bytes} B`;
  if (bytes < 1_000_000) return `${Math.ceil(bytes / 1_000)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

type Translate = ReturnType<typeof useI18n>["t"];

/** MetaTeam's progress and state words, shown in the user's language. */
function progressLabel(value: string, t: Translate) {
  switch (value) {
    case "plan":
      return t("inbox.progress_plan");
    case "todo":
      return t("inbox.progress_todo");
    case "doing":
      return t("inbox.progress_doing");
    case "done":
      return t("inbox.progress_done");
    default:
      return value;
  }
}

function stateLabel(value: string, t: Translate) {
  switch (value) {
    case "active":
      return t("inbox.state_active");
    case "closed":
      return t("inbox.state_closed");
    case "deleted":
      return t("inbox.state_deleted");
    default:
      return value;
  }
}

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}

type InboxNote = NonNullable<InboxTaskView["lastNote"]>;

function NoteLine({ note }: { note: InboxNote }) {
  const formats = useTimeFormats();
  return (
    <>
      <p className="inbox-note-text">{note.text}</p>
      {(note.by !== null || note.atMs !== null) && (
        <p className="inbox-note-meta">
          {[
            note.by,
            note.atMs === null
              ? null
              : formats.dateTime.format(new Date(Number(note.atMs))),
          ]
            .filter((part) => part !== null)
            .join(" · ")}
        </p>
      )}
    </>
  );
}

function TaskDetailBody({
  task,
  onOpen,
}: {
  task: InboxTaskView;
  onOpen: (id: string) => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  // The latest note already leads the list when MetaTeam includes it.
  const notes = task.notes;
  return (
    <>
      {task.description && (
        <Dialog.Description className="inbox-task-description">
          {task.description}
        </Dialog.Description>
      )}
      <dl className="inbox-task-facts">
        <Fact label={t("inbox.task_id")}>{task.id}</Fact>
        {task.progress && (
          <Fact label={t("inbox.task_status")}>
            <Badge className="whitespace-nowrap">
              {progressLabel(task.progress, t)}
            </Badge>
          </Fact>
        )}
        {task.state && (
          <Fact label={t("inbox.task_state")}>{stateLabel(task.state, t)}</Fact>
        )}
        {task.assignees.length > 0 && (
          <Fact label={t("inbox.task_assignees")}>
            {task.assignees.join(t("inbox.list_separator"))}
          </Fact>
        )}
        {task.createdBy && (
          <Fact label={t("inbox.task_created_by")}>{task.createdBy}</Fact>
        )}
        {task.path && <Fact label={t("inbox.task_path")}>{task.path}</Fact>}
        {task.updatedAtMs && (
          <Fact label={t("inbox.task_updated")}>
            {formats.dateTime.format(new Date(Number(task.updatedAtMs)))}
          </Fact>
        )}
      </dl>
      {task.lastNote && (
        <section className="inbox-detail-section">
          <h3>{t("inbox.task_last_note")}</h3>
          <NoteLine note={task.lastNote} />
        </section>
      )}
      {notes.length > 0 && (
        <section className="inbox-detail-section">
          <h3>{t("inbox.task_notes")}</h3>
          <ol className="inbox-notes">
            {notes.map((note, index) => (
              <li key={index}>
                <NoteLine note={note} />
              </li>
            ))}
          </ol>
        </section>
      )}
      {task.children.length > 0 && (
        <section className="inbox-detail-section">
          <h3>{t("inbox.task_children")}</h3>
          <ul className="inbox-detail-links">
            {task.children.map((child) => (
              <li key={child.id}>
                <button
                  type="button"
                  className="inbox-detail-link focus-ring"
                  onClick={() => onOpen(child.id)}
                >
                  <span>{child.name}</span>
                  {child.progress && (
                    <Badge className="whitespace-nowrap">
                      {progressLabel(child.progress, t)}
                    </Badge>
                  )}
                  <Icon name="chevron-right" />
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}

function FileDetailBody({
  file,
  download,
  onDownload,
}: {
  file: InboxFileView;
  download: DownloadStatus;
  onDownload: () => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  const downloadNote =
    download === "opened"
      ? t("inbox.download_opened")
      : download === "not_downloadable"
        ? t("inbox.download_unavailable")
        : download === "forbidden"
          ? t("inbox.task_forbidden")
          : download === "not_found"
            ? t("inbox.task_not_found")
            : download === "failed"
              ? t("inbox.download_failed")
              : null;
  return (
    <>
      {file.description && (
        <Dialog.Description className="inbox-task-description">
          {file.description}
        </Dialog.Description>
      )}
      <dl className="inbox-task-facts">
        {file.sizeBytes && (
          <Fact label={t("inbox.file_size")}>{formatSize(file.sizeBytes)}</Fact>
        )}
        {file.mime && <Fact label={t("inbox.file_type")}>{file.mime}</Fact>}
        {file.tag && <Fact label={t("inbox.file_tag")}>{file.tag}</Fact>}
        {file.path && <Fact label={t("inbox.task_path")}>{file.path}</Fact>}
        {file.by && <Fact label={t("inbox.file_by")}>{file.by}</Fact>}
        {file.updatedAtMs && (
          <Fact label={t("inbox.task_updated")}>
            {formats.dateTime.format(new Date(Number(file.updatedAtMs)))}
          </Fact>
        )}
      </dl>
      {file.content !== null && (
        <section className="inbox-detail-section">
          <h3>{t("inbox.file_preview")}</h3>
          <pre className="inbox-file-preview">{file.content}</pre>
          {file.contentTruncated && (
            <p className="inbox-message-note">
              {t("inbox.file_preview_truncated")}
            </p>
          )}
        </section>
      )}
      {file.downloadable && (
        <div className="inbox-detail-actions">
          <Button
            type="button"
            size="sm"
            variant="secondary"
            disabled={download === "opening"}
            onClick={onDownload}
          >
            <Icon name="download" />
            {download === "opening"
              ? t("inbox.download_opening")
              : t("inbox.download")}
          </Button>
          {downloadNote && (
            <span className="inbox-message-note" role="status">
              {downloadNote}
            </span>
          )}
        </div>
      )}
    </>
  );
}

function ProjectDetailBody({
  project,
  onOpen,
}: {
  project: InboxProjectView;
  onOpen: (id: string) => void;
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  return (
    <>
      {project.description && (
        <Dialog.Description className="inbox-task-description">
          {project.description}
        </Dialog.Description>
      )}
      <dl className="inbox-task-facts">
        <Fact label={t("inbox.task_id")}>{project.id}</Fact>
        {project.path && (
          <Fact label={t("inbox.task_path")}>{project.path}</Fact>
        )}
        {project.updatedAtMs && (
          <Fact label={t("inbox.task_updated")}>
            {formats.dateTime.format(new Date(Number(project.updatedAtMs)))}
          </Fact>
        )}
      </dl>
      {project.fileTags.length > 0 && (
        <section className="inbox-detail-section">
          <h3>{t("inbox.project_file_tags")}</h3>
          <ul className="inbox-file-tags">
            {project.fileTags.map((tag) => (
              <li key={tag.tag}>
                <Badge className="whitespace-nowrap">
                  {t("inbox.project_file_tag", {
                    tag: tag.tag,
                    count: Number(tag.count),
                  })}
                </Badge>
              </li>
            ))}
          </ul>
        </section>
      )}
      <section className="inbox-detail-section">
        <h3>{t("inbox.project_files")}</h3>
        {project.files.length === 0 ? (
          <p className="inbox-message-note">{t("inbox.project_no_files")}</p>
        ) : (
          <ul className="inbox-detail-links">
            {project.files.map((file) => (
              <li key={file.id}>
                <button
                  type="button"
                  className="inbox-detail-link focus-ring"
                  onClick={() => onOpen(file.id)}
                >
                  <span>{file.name}</span>
                  <span className="inbox-detail-link-meta">
                    {[file.tag, file.sizeBytes && formatSize(file.sizeBytes)]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                  <Icon name="chevron-right" />
                </button>
              </li>
            ))}
          </ul>
        )}
        {project.filesTruncated && (
          <p className="inbox-message-note">{t("inbox.project_files_more")}</p>
        )}
      </section>
    </>
  );
}

function InboxTaskDialog({
  task,
  onClose,
  onOpen,
  onBack,
  onDownload,
}: {
  task: OpenedTask | null;
  onClose: () => void;
  onOpen: (id: string) => void;
  onBack: () => void;
  onDownload: (id: string) => void;
}) {
  const { t } = useI18n();
  const detail = task?.detail ?? null;
  const item = detail?.task ?? detail?.file ?? detail?.project ?? null;
  const icon = detail?.file
    ? "skill-file"
    : detail?.project
      ? "workspace"
      : "new-task";
  return (
    <Dialog.Root
      open={task !== null}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup className="inbox-detail-dialog">
          <div className="inbox-task-dialog-header">
            {task && task.trail.length > 0 && (
              <button
                type="button"
                className="icon-button"
                aria-label={t("inbox.detail_back")}
                onClick={onBack}
              >
                <Icon name="arrow-left" />
              </button>
            )}
            <span className="inbox-task-icon">
              <Icon name={icon} />
            </span>
            <Dialog.Title>
              {item?.name ??
                (task ? t("inbox.item_number", { id: task.taskId }) : "")}
            </Dialog.Title>
            <Dialog.Close
              className="icon-button"
              aria-label={t("common.close")}
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          <div className="inbox-detail-body">
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
            {detail?.task && (
              <TaskDetailBody task={detail.task} onOpen={onOpen} />
            )}
            {detail?.file && task && (
              <FileDetailBody
                file={detail.file}
                download={task.download}
                onDownload={() => onDownload(task.taskId)}
              />
            )}
            {detail?.project && (
              <ProjectDetailBody project={detail.project} onOpen={onOpen} />
            )}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/**
 * Whether each recipient of something the user sent has read it: one
 * status for a single recipient, every recipient by name for a group.
 */
function ReadReceipts({
  recipients,
}: {
  recipients: InboxMessage["recipients"];
}) {
  const { t } = useI18n();
  const formats = useTimeFormats();
  if (recipients.length === 0) return null;
  const status = (recipient: InboxMessage["recipients"][number]) =>
    recipient.read ? t("inbox.read") : t("inbox.not_read");
  const title = (recipient: InboxMessage["recipients"][number]) =>
    recipient.readAtMs === null
      ? undefined
      : t("inbox.read_at", {
          time: formats.dateTime.format(new Date(Number(recipient.readAtMs))),
        });
  if (recipients.length === 1) {
    const [only] = recipients;
    return (
      <p
        className="inbox-message-receipt"
        data-read={only.read}
        title={title(only)}
      >
        {status(only)}
      </p>
    );
  }
  return (
    <ul className="inbox-message-receipts" aria-label={t("inbox.receipts")}>
      {recipients.map((recipient) => (
        <li
          key={recipient.peerId}
          data-read={recipient.read}
          title={title(recipient)}
        >
          {t("inbox.receipt", {
            name: recipient.name,
            status: status(recipient),
          })}
        </li>
      ))}
    </ul>
  );
}

function sendFailureText(failure: SendFailure, t: Translate) {
  switch (failure) {
    case "failed":
      return t("inbox.send_failed");
    case "busy":
      return t("inbox.send_busy");
    case "unavailable":
      return t("inbox.send_unavailable");
    case "unknown_peer":
      return t("inbox.send_unknown_peer");
    case "rejected":
      return t("inbox.send_rejected");
    case "forbidden":
      return t("inbox.send_forbidden");
    case "not_found":
      return t("inbox.send_not_found");
  }
}

/**
 * The reply box. Enter sends and Shift+Enter starts a new line; nothing is
 * sent while an input method is composing or a message is on its way.
 */
export function InboxComposer({
  name,
  text,
  sending,
  failure,
  onChange,
  onSend,
}: {
  name: string;
  text: string;
  sending: boolean;
  failure: SendFailure | null;
  onChange: (text: string) => void;
  onSend: () => void;
}) {
  const { t } = useI18n();
  const empty = text.trim() === "";
  return (
    <form
      className="inbox-composer"
      aria-busy={sending || undefined}
      onSubmit={(event) => {
        event.preventDefault();
        if (!sending && !empty) onSend();
      }}
    >
      {failure && (
        <div className="inbox-composer-failure" role="alert">
          <span>{sendFailureText(failure, t)}</span>
          {sendRetryable(failure) && (
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={sending}
              onClick={onSend}
            >
              {t("inbox.retry")}
            </Button>
          )}
        </div>
      )}
      <div className="inbox-composer-row">
        <textarea
          className="inbox-composer-input focus-ring"
          aria-label={t("inbox.composer_label", { name })}
          placeholder={t("inbox.composer_placeholder")}
          rows={2}
          value={text}
          readOnly={sending}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (
              event.key !== "Enter" ||
              event.shiftKey ||
              event.nativeEvent.isComposing
            )
              return;
            event.preventDefault();
            if (!sending && !empty) onSend();
          }}
        />
        <Button type="submit" size="md" disabled={sending || empty}>
          <Icon name="send" />
          {sending ? t("inbox.sending") : t("inbox.send")}
        </Button>
      </div>
    </form>
  );
}

function InboxConversationView({
  name,
  conversation,
  composer,
  onLoadEarlier,
  onOpenTask,
  onRetry,
  onDraft,
  onSend,
}: {
  name: string;
  conversation: OpenedConversation;
  composer: Composer | null;
  onLoadEarlier: () => void;
  onOpenTask: (taskId: string) => void;
  onRetry: () => void;
  onDraft: (text: string) => void;
  onSend: () => void;
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
            const receipts = outgoing
              ? message.recipients.filter(
                  (recipient) => recipient.peerId !== message.fromPeerId,
                )
              : [];
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
                    {message.fromAgent !== null && (
                      <small>
                        {t("inbox.sent_by_agent", {
                          agent: message.fromAgent,
                        })}
                      </small>
                    )}
                    <time dateTime={sentAt.toISOString()}>
                      {formats.time.format(sentAt)}
                    </time>
                    {message.isNew && (
                      <Badge className="inbox-new-badge">
                        {t("inbox.new_message")}
                      </Badge>
                    )}
                  </div>
                  <div className="inbox-bubble">
                    <p>{message.text}</p>
                  </div>
                  <ReadReceipts recipients={receipts} />
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
      {composer?.peerId === conversation.peerId && (
        <InboxComposer
          name={name}
          text={composer.text}
          sending={composer.sending}
          failure={composer.failure}
          onChange={onDraft}
          onSend={onSend}
        />
      )}
    </section>
  );
}

/**
 * The reading area: the connection state when there is nothing to read,
 * otherwise the selected conversation and its reply box.
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
          composer={controller.composer}
          onLoadEarlier={controller.loadEarlierMessages}
          onOpenTask={(taskId) => void controller.openTask(taskId)}
          onRetry={controller.retry}
          onDraft={controller.setDraft}
          onSend={() => void controller.send()}
        />
      ) : (
        <InboxNotice
          title={t("inbox.pick_conversation")}
          hint={t("inbox.pick_hint")}
        />
      )}
      <InboxTaskDialog
        task={controller.task}
        onClose={controller.closeTask}
        onOpen={controller.openNested}
        onBack={controller.back}
        onDownload={(id) => void controller.downloadFile(id)}
      />
    </>
  );
}
