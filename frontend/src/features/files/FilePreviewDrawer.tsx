import type { FilePreview, FileReferenceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
import { useI18n } from "../../i18n/context.ts";

export type FilePreviewDrawerState = {
  references: FileReferenceView[];
  selected: FileReferenceView;
  phase: "loading" | "settled";
  preview: FilePreview | null;
};

export function FilePreviewDrawer({
  state,
  onSelect,
  onRefresh,
  onClose,
}: {
  state: FilePreviewDrawerState;
  onSelect: (reference: FileReferenceView) => void;
  onRefresh: () => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const multiple = state.references.length > 1;
  const ready = state.phase === "settled" && state.preview?.state === "ready";
  const status = state.phase === "loading" ? "loading" : state.preview?.state;
  const failureMessage =
    status && status !== "loading" && status !== "ready"
      ? (`file_preview.state.${status}` as const)
      : "file_preview.state.error";

  return (
    <Drawer.Root open onOpenChange={(open) => !open && onClose()}>
      <Drawer.Portal>
        <Drawer.Backdrop />
        <Drawer.Popup
          className="w-[min(760px,calc(100vw-28px))] bg-(--ui-surface-canvas) max-[620px]:w-full"
          aria-labelledby="file-preview-title"
          aria-describedby="file-preview-description"
        >
          <Drawer.Header className="items-center px-5 py-4">
            <div className="min-w-0">
              <Drawer.Title id="file-preview-title">
                {t("file_preview.title")}
              </Drawer.Title>
              <Drawer.Description
                id="file-preview-description"
                className="mt-1 truncate font-mono text-xs"
                title={state.selected.displayPath}
              >
                {state.selected.displayPath}
              </Drawer.Description>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Button
                type="button"
                variant="secondary"
                size="sm"
                disabled={state.phase === "loading"}
                onClick={onRefresh}
              >
                <Icon name="refresh" />
                {t("file_preview.refresh")}
              </Button>
              <Drawer.Close
                className="grid size-11 place-items-center rounded-lg text-(--ui-content-muted) hover:bg-(--ui-action-hover-surface) hover:text-(--ui-content-primary)"
                aria-label={t("file_preview.close")}
              >
                <Icon name="close" />
              </Drawer.Close>
            </div>
          </Drawer.Header>

          <div className="border-b border-(--ui-border) px-5 py-3 text-xs text-(--ui-content-muted)">
            {t("file_preview.current_content_notice")}
          </div>

          <Drawer.Body className="min-h-0 overflow-hidden p-0">
            <div
              className={
                multiple
                  ? "grid h-full min-h-0 grid-cols-[208px_minmax(0,1fr)] max-[620px]:grid-cols-1 max-[620px]:grid-rows-[auto_minmax(0,1fr)]"
                  : "h-full min-h-0"
              }
            >
              {multiple && (
                <nav
                  className="min-h-0 overflow-y-auto border-r border-(--ui-border) bg-(--ui-surface-panel) p-2 max-[620px]:max-h-44 max-[620px]:border-r-0 max-[620px]:border-b"
                  aria-label={t("file_preview.references")}
                >
                  {state.references.map((reference) => {
                    const selected = reference.id === state.selected.id;
                    return (
                      <button
                        key={reference.id}
                        type="button"
                        className="focus-ring min-h-11 w-full truncate rounded-lg px-3 py-2 text-left font-mono text-xs text-(--ui-content-muted) aria-current:bg-(--ui-action-selected-surface) aria-current:text-(--ui-action-selected-content)"
                        aria-current={selected ? "true" : undefined}
                        aria-label={reference.displayPath}
                        title={reference.displayPath}
                        onClick={() => onSelect(reference)}
                      >
                        {reference.displayPath}
                      </button>
                    );
                  })}
                </nav>
              )}

              <section
                className="flex min-h-0 min-w-0 flex-col"
                aria-live="polite"
                aria-busy={state.phase === "loading"}
              >
                {status === "loading" ? (
                  <div className="grid flex-1 place-items-center p-8 text-sm text-(--ui-content-muted)">
                    <span className="flex items-center gap-2">
                      <Icon name="loading" />
                      {t("file_preview.loading")}
                    </span>
                  </div>
                ) : ready && state.preview ? (
                  <>
                    {(state.preview.truncated || state.preview.redacted) && (
                      <div className="flex flex-wrap gap-x-4 gap-y-1 border-b border-(--ui-border) px-4 py-2 text-xs text-(--ui-content-muted)">
                        {state.preview.truncated && (
                          <span>{t("file_preview.state.truncated")}</span>
                        )}
                        {state.preview.redacted && (
                          <span>{t("file_preview.state.redacted")}</span>
                        )}
                      </div>
                    )}
                    <pre className="min-h-0 flex-1 overflow-auto bg-(--ui-surface-canvas) p-5 font-mono text-[13px] leading-6 whitespace-pre text-(--ui-content-primary) [tab-size:4]">
                      {state.preview.content}
                    </pre>
                  </>
                ) : (
                  <div className="grid flex-1 place-items-center p-8 text-center">
                    <div className="max-w-sm">
                      <p className="m-0 text-sm font-medium text-(--ui-content-primary)">
                        {t(failureMessage)}
                      </p>
                      {(status === "changing" || status === "error") && (
                        <Button
                          type="button"
                          variant="secondary"
                          size="sm"
                          className="mt-4"
                          onClick={onRefresh}
                        >
                          {t("file_preview.retry")}
                        </Button>
                      )}
                    </div>
                  </div>
                )}
              </section>
            </div>
          </Drawer.Body>
        </Drawer.Popup>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
