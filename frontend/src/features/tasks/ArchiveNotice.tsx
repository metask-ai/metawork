import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export type ArchiveNoticeValue = {
  id: number;
  taskId: string;
  kind: "archived" | "failed";
};

export function ArchiveNotice({
  notice,
  disabled,
  onUndo,
  onView,
  onDismiss,
}: {
  notice: ArchiveNoticeValue;
  disabled: boolean;
  onUndo: () => void;
  onView: () => void;
  onDismiss: () => void;
}) {
  const { t } = useI18n();
  const remaining = useRef(8000);
  const dismiss = useRef(onDismiss);
  dismiss.current = onDismiss;
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    remaining.current = 8000;
  }, [notice.id]);
  useEffect(() => {
    if (hovered || focused || disabled) return;
    const started = performance.now();
    const timer = window.setTimeout(() => dismiss.current(), remaining.current);
    return () => {
      window.clearTimeout(timer);
      remaining.current = Math.max(
        0,
        remaining.current - (performance.now() - started),
      );
    };
  }, [notice.id, hovered, focused, disabled]);
  return createPortal(
    <div
      className="archive-notice"
      data-native-window-drag-exclude=""
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocusCapture={() => setFocused(true)}
      onBlurCapture={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null))
          setFocused(false);
      }}
    >
      <p role="status">
        {t(
          notice.kind === "archived"
            ? "archive.success"
            : "task.archive_failed",
        )}
      </p>
      {notice.kind === "archived" && (
        <div className="archive-notice-actions">
          <Button
            variant="secondary"
            size="sm"
            disabled={disabled}
            onClick={onUndo}
          >
            {t("archive.undo")}
          </Button>
          <Button variant="ghost" size="sm" onClick={onView}>
            {t("archive.view")}
          </Button>
        </div>
      )}
      <Button
        variant="ghost"
        size="icon"
        aria-label={t("common.close")}
        onClick={onDismiss}
      >
        <Icon name="close" />
      </Button>
    </div>,
    document.body,
  );
}
