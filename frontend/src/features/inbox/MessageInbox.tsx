import { useLayoutEffect, useRef, useState } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { Badge } from "../../components/ui/badge.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import {
  Textarea,
  useAutosizeTextarea,
} from "../../components/ui/textarea.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";
import { isInputMethodKey } from "../../platform/keyboard.ts";
import {
  sampleConversations,
  type InboxConversation,
  type InboxMessage,
  type InboxTask,
} from "./sample-inbox.ts";

type InboxEntry = { conversation: InboxConversation; unread: number };
type OpenedConversation = { draft: string; replies: readonly InboxMessage[] };
const emptyConversation: OpenedConversation = { draft: "", replies: [] };

function messageText(message: InboxMessage, language: "en-US" | "zh-CN") {
  return typeof message.text === "string"
    ? message.text
    : message.text[language];
}

export function useMessageInbox() {
  const [opened, setOpened] = useState<{
    selectedId: string | null;
    conversations: Readonly<Partial<Record<string, OpenedConversation>>>;
  }>({ selectedId: null, conversations: {} });
  const { selectedId } = opened;
  const entries = sampleConversations.map<InboxEntry>((conversation) => {
    const thread = opened.conversations[conversation.id];
    return {
      conversation: thread?.replies.length
        ? {
            ...conversation,
            messages: [...conversation.messages, ...thread.replies],
          }
        : conversation,
      unread: thread
        ? 0
        : conversation.messages.filter((message) => message.unread).length,
    };
  });
  entries.sort(
    (left, right) =>
      Date.parse(right.conversation.messages.at(-1)!.sentAt) -
      Date.parse(left.conversation.messages.at(-1)!.sentAt),
  );

  function updateSelected(
    update: (thread: OpenedConversation) => OpenedConversation,
  ) {
    if (selectedId === null) return;
    setOpened((current) => {
      const thread = current.conversations[selectedId];
      if (!thread) return current;
      const updated = update(thread);
      if (updated === thread) return current;
      return {
        ...current,
        conversations: { ...current.conversations, [selectedId]: updated },
      };
    });
  }

  return {
    entries,
    selected: entries.find(({ conversation }) => conversation.id === selectedId)
      ?.conversation,
    unread: entries.reduce((count, entry) => count + entry.unread, 0),
    draft:
      selectedId === null
        ? ""
        : (opened.conversations[selectedId]?.draft ?? ""),
    openConversation(id: string) {
      setOpened(({ conversations }) => ({
        selectedId: id,
        conversations: conversations[id]
          ? conversations
          : { ...conversations, [id]: emptyConversation },
      }));
    },
    updateDraft(draft: string) {
      updateSelected((thread) => ({ ...thread, draft }));
    },
    sendReply() {
      const sentAt = new Date().toISOString();
      updateSelected((thread) => {
        const text = thread.draft.trim();
        if (!text) return thread;
        return {
          draft: "",
          replies: [
            ...thread.replies,
            {
              id: `reply-${thread.replies.length + 1}`,
              sentAt,
              direction: "outgoing",
              text,
            },
          ],
        };
      });
    },
  };
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
        aria-label={t("inbox.title")}
        aria-description={
          unread ? t("inbox.unread", { count: unread }) : undefined
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
            {unread}
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

export function InboxConversationList({
  entries,
  selectedId,
  onSelect,
}: {
  entries: readonly InboxEntry[];
  selectedId?: string;
  onSelect: (id: string) => void;
}) {
  const { t, locale } = useI18n();
  const language = locale === "zh-CN" ? "zh-CN" : "en-US";
  const time = new Intl.DateTimeFormat(language, {
    hour: "numeric",
    minute: "2-digit",
  });
  const day = new Intl.DateTimeFormat(language, {
    month: "numeric",
    day: "numeric",
  });
  const dateTime = new Intl.DateTimeFormat(language, {
    dateStyle: "medium",
    timeStyle: "short",
  });
  const today = new Date().toDateString();

  return (
    <section className="inbox-list" aria-labelledby="inbox-list-title">
      <h2 id="inbox-list-title">{t("inbox.title")}</h2>
      <ul className="inbox-list-scroll">
        {entries.map(({ conversation, unread }) => {
          const name = conversation.name[language];
          const latest = conversation.messages.at(-1)!;
          const sentAt = new Date(latest.sentAt);
          return (
            <li key={conversation.id}>
              <button
                type="button"
                className="inbox-list-row focus-ring"
                aria-label={name}
                aria-description={
                  unread ? t("inbox.unread", { count: unread }) : undefined
                }
                aria-current={
                  selectedId === conversation.id ? "true" : undefined
                }
                data-unread={unread > 0}
                onClick={() => onSelect(conversation.id)}
              >
                <InboxAvatar name={name} />
                <span className="inbox-row-copy">
                  <strong>{name}</strong>
                  <span>{messageText(latest, language)}</span>
                </span>
                <span className="inbox-row-meta">
                  <time
                    dateTime={latest.sentAt}
                    title={dateTime.format(sentAt)}
                  >
                    {today === sentAt.toDateString()
                      ? time.format(sentAt)
                      : day.format(sentAt)}
                  </time>
                  {unread > 0 && (
                    <span className="inbox-unread-badge" aria-hidden="true">
                      {unread}
                    </span>
                  )}
                </span>
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function LinkedInboxTask({ task }: { task: InboxTask }) {
  const { t, locale } = useI18n();
  const language = locale === "zh-CN" ? "zh-CN" : "en-US";
  const status = t(`inbox.task_status.${task.status}`);

  return (
    <Dialog.Root>
      <Dialog.Trigger className="inbox-task-card">
        <span className="inbox-task-icon">
          <Icon name="new-task" />
        </span>
        <span className="inbox-task-caption">
          <span>{t("inbox.linked_task")}</span>
          <strong>{task.title[language]}</strong>
        </span>
        <span className="inbox-task-end">
          <Badge
            variant={task.status === "done" ? "success" : "neutral"}
            className="shrink-0 whitespace-nowrap"
          >
            {status}
          </Badge>
          <Icon name="chevron-right" />
        </span>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup>
          <div className="inbox-task-dialog-header">
            <span className="inbox-task-icon">
              <Icon name="new-task" />
            </span>
            <Dialog.Title>{task.title[language]}</Dialog.Title>
            <Dialog.Close
              className="icon-button"
              aria-label={t("common.close")}
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          <Dialog.Description className="inbox-task-description">
            {task.description[language]}
          </Dialog.Description>
          <dl className="inbox-task-facts">
            <div>
              <dt>{t("inbox.task_owner")}</dt>
              <dd>{task.assignee[language]}</dd>
            </div>
            <div>
              <dt>{t("inbox.task_status")}</dt>
              <dd>{status}</dd>
            </div>
          </dl>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function InboxReplyForm({
  name,
  draft,
  onDraftChange,
  onSend,
}: {
  name: string;
  draft: string;
  onDraftChange: (value: string) => void;
  onSend: () => void;
}) {
  const { t } = useI18n();
  const editor = useRef<HTMLTextAreaElement>(null);
  const composing = useRef(false);
  useAutosizeTextarea(editor, draft);
  const canSend = draft.trim().length > 0;
  const label = t("inbox.reply_to", { name });

  function submitReply() {
    if (!canSend || composing.current) return;
    onSend();
    editor.current?.focus();
  }

  return (
    <form
      className="inbox-reply-bar"
      onSubmit={(event) => {
        event.preventDefault();
        submitReply();
      }}
    >
      <div className="inbox-reply-form">
        <Textarea
          ref={editor}
          className="min-h-11 min-w-0 resize-none py-2.5 leading-6 motion-reduce:transition-none"
          rows={1}
          enterKeyHint="send"
          aria-label={label}
          placeholder={`${label}…`}
          value={draft}
          onChange={(event) => onDraftChange(event.currentTarget.value)}
          onCompositionStart={() => {
            composing.current = true;
          }}
          onCompositionEnd={() => {
            composing.current = false;
          }}
          onBlur={() => {
            composing.current = false;
          }}
          onKeyDown={(event) => {
            if (
              event.defaultPrevented ||
              event.key !== "Enter" ||
              event.shiftKey ||
              event.altKey ||
              event.ctrlKey ||
              event.metaKey ||
              isInputMethodKey(event.nativeEvent, composing.current)
            )
              return;
            event.preventDefault();
            submitReply();
          }}
        />
        <Button
          type="submit"
          size="icon"
          className="size-11 rounded-full bg-(--ui-content-primary) text-(--ui-surface-panel) hover:bg-(--ui-content-muted) disabled:bg-(--ui-surface-panel-2) disabled:text-(--ui-content-muted)"
          disabled={!canSend}
          aria-label={t("inbox.send_reply")}
          title={t("inbox.send_reply")}
        >
          <Icon name="send" />
        </Button>
      </div>
    </form>
  );
}

export function InboxConversationView({
  conversation,
  draft,
  onDraftChange,
  onSend,
}: {
  conversation?: InboxConversation;
  draft: string;
  onDraftChange: (value: string) => void;
  onSend: () => void;
}) {
  const { t, locale } = useI18n();
  const language = locale === "zh-CN" ? "zh-CN" : "en-US";
  const transcript = useRef<HTMLDivElement>(null);
  const conversationId = conversation?.id;
  const messageCount = conversation?.messages.length;
  useLayoutEffect(() => {
    const scroll = transcript.current;
    if (scroll) scroll.scrollTop = scroll.scrollHeight;
  }, [conversationId, messageCount]);
  const time = new Intl.DateTimeFormat(language, {
    hour: "numeric",
    minute: "2-digit",
  });
  const date = new Intl.DateTimeFormat(language, { dateStyle: "medium" });

  if (!conversation)
    return (
      <div className="inbox-empty">
        <span className="inbox-empty-icon">
          <Icon name="messages" />
        </span>
        <h1>{t("inbox.pick_conversation")}</h1>
        <p>{t("inbox.pick_hint")}</p>
        <Badge className="mt-1 whitespace-nowrap text-(--ui-content-muted)">
          {t("inbox.sample")}
        </Badge>
      </div>
    );

  const name = conversation.name[language];
  return (
    <section
      key={conversation.id}
      className="inbox-detail"
      aria-labelledby="inbox-conversation-title"
    >
      <header className="inbox-detail-header">
        <InboxAvatar name={name} />
        <h1 id="inbox-conversation-title">{name}</h1>
        <Badge className="ms-auto shrink-0 whitespace-nowrap text-(--ui-content-muted)">
          {t("inbox.sample")}
        </Badge>
      </header>
      <div className="inbox-transcript-scroll" ref={transcript}>
        <ol className="inbox-transcript">
          {conversation.messages.map((message, index) => {
            const sentAt = new Date(message.sentAt);
            const previous = conversation.messages[index - 1];
            const startsDay =
              !previous ||
              sentAt.toDateString() !==
                new Date(previous.sentAt).toDateString();
            return (
              <li className="inbox-transcript-entry" key={message.id}>
                {startsDay && (
                  <div className="inbox-transcript-date">
                    <time dateTime={message.sentAt}>{date.format(sentAt)}</time>
                  </div>
                )}
                <div
                  className="inbox-message"
                  data-direction={message.direction}
                  data-linked-task={message.task !== undefined}
                >
                  <div className="inbox-message-meta">
                    <span>
                      {message.direction === "outgoing"
                        ? t("inbox.sender_self")
                        : name}
                    </span>
                    <time dateTime={message.sentAt}>{time.format(sentAt)}</time>
                  </div>
                  <div className="inbox-bubble">
                    <p>{messageText(message, language)}</p>
                  </div>
                  {message.task && <LinkedInboxTask task={message.task} />}
                </div>
              </li>
            );
          })}
        </ol>
      </div>
      <InboxReplyForm
        name={name}
        draft={draft}
        onDraftChange={onDraftChange}
        onSend={onSend}
      />
    </section>
  );
}
