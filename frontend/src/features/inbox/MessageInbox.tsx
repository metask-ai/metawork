import { useState } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  sampleConversations,
  type InboxConversation,
  type InboxTask,
} from "./sample-inbox.ts";

type InboxEntry = { conversation: InboxConversation; unread: number };

export function useMessageInbox() {
  const [opened, setOpened] = useState<{
    selectedId: string | null;
    readIds: ReadonlySet<string>;
  }>({ selectedId: null, readIds: new Set() });
  const entries: InboxEntry[] = sampleConversations.map((conversation) => ({
    conversation,
    unread: opened.readIds.has(conversation.id)
      ? 0
      : conversation.messages.filter((message) => message.unread).length,
  }));

  return {
    entries,
    selected: sampleConversations.find(({ id }) => id === opened.selectedId),
    unread: entries.reduce((count, entry) => count + entry.unread, 0),
    openConversation(id: string) {
      setOpened(({ readIds }) => ({
        selectedId: id,
        readIds: readIds.has(id) ? readIds : new Set([...readIds, id]),
      }));
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
                onClick={() => onSelect(conversation.id)}
              >
                <InboxAvatar name={name} />
                <span className="inbox-row-copy">
                  <strong>{name}</strong>
                  <span>{latest.text[language]}</span>
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
        <Icon name="chevron-right" />
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup>
          <div className="inbox-task-dialog-header">
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

export function InboxConversationView({
  conversation,
}: {
  conversation?: InboxConversation;
}) {
  const { t, locale } = useI18n();
  const language = locale === "zh-CN" ? "zh-CN" : "en-US";
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
        <span className="inbox-sample">{t("inbox.sample")}</span>
      </div>
    );

  const name = conversation.name[language];
  return (
    <section
      className="inbox-detail"
      aria-labelledby="inbox-conversation-title"
    >
      <header className="inbox-detail-header">
        <InboxAvatar name={name} />
        <h1 id="inbox-conversation-title">{name}</h1>
        <span className="inbox-sample">{t("inbox.sample")}</span>
      </header>
      <div className="inbox-transcript-scroll" key={conversation.id}>
        <p className="inbox-transcript-date">
          {date.format(new Date(conversation.messages[0].sentAt))}
        </p>
        <ol className="inbox-transcript">
          {conversation.messages.map((message) => (
            <li
              className="inbox-message"
              key={message.id}
              data-direction={message.direction}
            >
              <div className="inbox-message-meta">
                <span>
                  {message.direction === "outgoing"
                    ? t("inbox.sender_self")
                    : name}
                </span>
                <time dateTime={message.sentAt}>
                  {time.format(new Date(message.sentAt))}
                </time>
              </div>
              <div className="inbox-bubble">
                <p>{message.text[language]}</p>
                {message.task && <LinkedInboxTask task={message.task} />}
              </div>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
