import { Icon } from "../../components/ui/Icon.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";

export function MessageNavigationItem({
  active,
  onOpen,
}: {
  active: boolean;
  onOpen: () => void;
}) {
  const { t } = useI18n();
  return (
    <Tooltip.Root>
      <Tooltip.Trigger
        type="button"
        className="primary-navigation-item focus-ring"
        aria-label={t("inbox.title")}
        aria-current={active ? "page" : undefined}
        onClick={onOpen}
      >
        <Icon name="messages" />
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Positioner side="right">
          <Tooltip.Popup>{t("inbox.title")}</Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

export function InboxSidebar() {
  const { t } = useI18n();
  return (
    <section className="inbox-list" aria-labelledby="inbox-list-title">
      <h2 id="inbox-list-title">{t("inbox.title")}</h2>
    </section>
  );
}

export function InboxUnavailable() {
  const { t } = useI18n();
  return (
    <div className="inbox-empty">
      <span className="inbox-empty-icon" aria-hidden="true">
        <Icon name="messages" />
      </span>
      <h1>{t("inbox.unavailable")}</h1>
    </div>
  );
}
