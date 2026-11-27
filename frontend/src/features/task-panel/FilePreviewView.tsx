import {
  useFileMenuTrigger,
  type MenuFile,
} from "../../components/FileMenu.tsx";
import { previewImageCopy } from "../../components/preview-image-copy.ts";
import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { useLayoutEffect, useRef, useState } from "react";
import type {
  FilePreview,
  FilePreviewImage,
  FileReferenceView,
} from "../../bridge/contracts.ts";
import {
  Markdown,
  type MarkdownWebLink,
} from "../../components/ai/Markdown.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Tabs } from "../../components/ui/tabs.tsx";
import { useI18n } from "../../i18n/context.ts";
import { ImageLightboxPopup } from "../../components/ImageLightboxPopup.tsx";
import { HighlightedSource } from "./HighlightedSource.tsx";
import type { FilePreviewMode } from "./useTaskPanelViewStates.ts";
export type FilePreviewViewState = {
  selected: FileReferenceView;
  phase: "loading" | "settled";
  preview: FilePreview | null;
};
function PreviewedImage({
  image,
  displayPath,
  file,
  onFailure,
}: {
  image: FilePreviewImage;
  displayPath: string;
  file: MenuFile | null;
  onFailure: () => void;
}) {
  const { t } = useI18n();
  const [decoded, setDecoded] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const trigger = useFileMenuTrigger(
    file && {
      ...file,
      copyImage: previewImageCopy(image, decoded),
    },
  );
  return (
    <Dialog.Root
      open={expanded}
      onOpenChange={(open) => {
        if (!open || (decoded && image.valid() && image.current()))
          setExpanded(open);
      }}
    >
      <div className="task-panel-preview-image">
        <Dialog.Trigger
          className="task-panel-preview-image-open"
          aria-label={t("file_preview.enlarge_image", { name: displayPath })}
          aria-disabled={!decoded || undefined}
          {...trigger}
        >
          <PreviewImageView
            image={image}
            alt={displayPath}
            onReady={() => setDecoded(true)}
            onFailure={() => {
              setDecoded(false);
              setExpanded(false);
              onFailure();
            }}
          />
        </Dialog.Trigger>
      </div>
      <ImageLightboxPopup name={displayPath.split("/").at(-1) || displayPath}>
        <PreviewImageView image={image} alt={displayPath} />
      </ImageLightboxPopup>
    </Dialog.Root>
  );
}

export function FilePreviewView({
  state,
  file = null,
  mode,
  scrollTop,
  onModeChange,
  onScrollTopChange,
  onRetry,
  webLink,
}: {
  state: FilePreviewViewState;
  file?: MenuFile | null;
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
  const failureMessage = state.preview?.reason
    ? (`file_preview.state.${state.preview.reason}` as const)
    : status && status !== "loading" && status !== "ready"
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
      {markdown && ready && !state.preview?.image && (
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
            {state.preview.image ? (
              <PreviewedImage
                key={JSON.stringify([
                  state.selected.id,
                  state.preview.image.id,
                ])}
                image={state.preview.image}
                displayPath={state.selected.displayPath}
                file={file}
                onFailure={() => state.preview?.release?.()}
              />
            ) : markdown ? (
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
