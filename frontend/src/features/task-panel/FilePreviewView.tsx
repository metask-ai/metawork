import { useLayoutEffect, useRef } from "react";
import type { FilePreview, FileReferenceView } from "../../bridge/contracts.ts";
import {
  Markdown,
  type MarkdownWebLink,
} from "../../components/ai/Markdown.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Tabs } from "../../components/ui/tabs.tsx";
import { useI18n } from "../../i18n/context.ts";
import { HighlightedSource } from "./HighlightedSource.tsx";
import type { FilePreviewMode } from "./useTaskPanelViewStates.ts";

export type FilePreviewViewState = {
  selected: FileReferenceView;
  phase: "loading" | "settled";
  preview: FilePreview | null;
};

export function FilePreviewView({
  state,
  mode,
  scrollTop,
  onModeChange,
  onScrollTopChange,
  onRetry,
  webLink,
}: {
  state: FilePreviewViewState;
  mode: FilePreviewMode;
  scrollTop: number;
  onModeChange: (mode: FilePreviewMode) => void;
  onScrollTopChange: (scrollTop: number) => void;
  onRetry: () => void;
  webLink: MarkdownWebLink;
}) {
  const { t } = useI18n();
  const root = useRef<HTMLDivElement | null>(null);
  const markdown = /\.(?:md|markdown)$/i.test(state.selected.displayPath);
  const ready = state.phase === "settled" && state.preview?.state === "ready";
  const status = state.phase === "loading" ? "loading" : state.preview?.state;
  const failureMessage =
    status && status !== "loading" && status !== "ready"
      ? (`file_preview.state.${status}` as const)
      : "file_preview.state.error";

  useLayoutEffect(() => {
    if (mode !== "preview") return;
    const document = root.current?.querySelector<HTMLElement>(
      ".task-panel-preview-document",
    );
    if (document) document.scrollTop = scrollTop;
  }, [mode, scrollTop, state.selected.id, status]);

  return (
    <Tabs.Root
      ref={root}
      render={<section />}
      value={mode}
      onValueChange={(value) => onModeChange(String(value) as FilePreviewMode)}
      className="task-panel-resource-view"
      aria-live="polite"
      aria-busy={state.phase === "loading"}
    >
      {markdown && ready && (
        <Tabs.List
          className="task-panel-preview-modes"
          aria-label={t("file_preview.mode")}
        >
          <Tabs.Tab value="preview">{t("file_preview.rendered")}</Tabs.Tab>
          <Tabs.Tab value="source">{t("file_preview.source")}</Tabs.Tab>
        </Tabs.List>
      )}

      <div className="task-panel-resource-body">
        {status === "loading" ? (
          <div className="task-panel-resource-state">
            <span>
              <Icon name="loading" />
              {t("file_preview.loading")}
            </span>
          </div>
        ) : ready && state.preview ? (
          <>
            {(state.preview.truncated || state.preview.redacted) && (
              <div className="task-panel-resource-flags">
                {state.preview.truncated && (
                  <span>{t("file_preview.state.truncated")}</span>
                )}
                {state.preview.redacted && (
                  <span>{t("file_preview.state.redacted")}</span>
                )}
              </div>
            )}
            {markdown ? (
              <>
                <Tabs.Panel
                  value="preview"
                  className="task-panel-preview-document"
                  onScroll={(event) =>
                    onScrollTopChange(event.currentTarget.scrollTop)
                  }
                >
                  <Markdown textResourcesOnly webLink={webLink}>
                    {state.preview.content}
                  </Markdown>
                </Tabs.Panel>
                <Tabs.Panel
                  value="source"
                  className="task-panel-preview-source"
                >
                  <HighlightedSource
                    displayPath={state.selected.displayPath}
                    content={state.preview.content}
                    scrollTop={scrollTop}
                    onScrollTopChange={onScrollTopChange}
                  />
                </Tabs.Panel>
              </>
            ) : (
              <HighlightedSource
                displayPath={state.selected.displayPath}
                content={state.preview.content}
                scrollTop={scrollTop}
                onScrollTopChange={onScrollTopChange}
              />
            )}
          </>
        ) : (
          <div className="task-panel-resource-state">
            <div>
              <p>{t(failureMessage)}</p>
              {(status === "changing" || status === "error") && (
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  onClick={onRetry}
                >
                  {t("file_preview.retry")}
                </Button>
              )}
            </div>
          </div>
        )}
      </div>
    </Tabs.Root>
  );
}

export function FilePreviewRefreshAction({
  state,
  onRefresh,
}: {
  state: FilePreviewViewState;
  onRefresh: () => void;
}) {
  const { t } = useI18n();

  return (
    <button
      type="button"
      className="task-panel-header-action focus-ring"
      aria-label={t("file_preview.refresh")}
      title={t("file_preview.refresh")}
      disabled={state.phase === "loading"}
      onClick={onRefresh}
    >
      <Icon name="refresh" />
    </button>
  );
}
