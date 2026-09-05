import type { FilePreview, FileReferenceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { SelectField } from "../../components/ui/select.tsx";
import { useI18n } from "../../i18n/context.ts";

export type FilePreviewViewState = {
  references: FileReferenceView[];
  selected: FileReferenceView;
  phase: "loading" | "settled";
  preview: FilePreview | null;
};

export function FilePreviewView({
  state,
  onSelect,
  onRefresh,
}: {
  state: FilePreviewViewState;
  onSelect: (reference: FileReferenceView) => void;
  onRefresh: () => void;
}) {
  const { t } = useI18n();
  const ready = state.phase === "settled" && state.preview?.state === "ready";
  const status = state.phase === "loading" ? "loading" : state.preview?.state;
  const failureMessage =
    status && status !== "loading" && status !== "ready"
      ? (`file_preview.state.${status}` as const)
      : "file_preview.state.error";

  return (
    <section
      className="task-panel-resource-view"
      aria-labelledby="task-panel-resource-title"
      aria-live="polite"
      aria-busy={state.phase === "loading"}
    >
      <header className="task-panel-resource-header">
        <div className="task-panel-resource-identity">
          <span className="task-panel-resource-kind">
            <Icon name="skill-file" />
            {t("task_panel.current_file")}
          </span>
          <h3 id="task-panel-resource-title" title={state.selected.displayPath}>
            {state.selected.displayPath}
          </h3>
        </div>
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
      </header>

      {state.references.length > 1 && (
        <div className="task-panel-resource-switcher">
          <SelectField
            value={state.selected.id}
            options={state.references.map((reference) => ({
              value: reference.id,
              label: reference.displayPath,
            }))}
            aria-label={t("file_preview.references")}
            onValueChange={(id) => {
              const reference = state.references.find(
                (candidate) => candidate.id === id,
              );
              if (reference) onSelect(reference);
            }}
          />
        </div>
      )}

      <p className="task-panel-resource-notice">
        {t("file_preview.current_content_notice")}
      </p>

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
            <pre className="task-panel-code">{state.preview.content}</pre>
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
                  onClick={onRefresh}
                >
                  {t("file_preview.retry")}
                </Button>
              )}
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
