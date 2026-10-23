import { useEffect, useId, useState, useSyncExternalStore } from "react";
import type { DocumentPreview } from "../bridge/document-preview.ts";
import type {
  DocumentCell,
  DocumentFailure,
  DocumentLayout,
  DocumentOpen,
  DocumentRegion,
} from "../bridge/document-contract.ts";
import { PreviewImageView } from "../components/PreviewImageView.tsx";
import { Button } from "../components/ui/button.tsx";
import { useI18n } from "../i18n/context.ts";

export function columnName(index: number) {
  let value = "";
  for (; index > 0; index = Math.floor((index - 1) / 26))
    value = String.fromCharCode(65 + ((index - 1) % 26)) + value;
  return value;
}

export function DocumentPreviewView(props: {
  preview: DocumentPreview;
  title: string;
  onRefresh: () => void;
  showRefreshAction?: boolean;
}) {
  return <DocumentPreviewContent key={props.preview.id} {...props} />;
}

function DocumentPreviewContent({
  preview,
  title,
  onRefresh,
  showRefreshAction = true,
}: {
  preview: DocumentPreview;
  title: string;
  onRefresh: () => void;
  showRefreshAction?: boolean;
}) {
  const { t } = useI18n();
  const state = useSyncExternalStore(
    preview.subscribe,
    preview.getSnapshot,
    preview.getSnapshot,
  );
  const document = state.state === "ready" ? state.document : undefined;
  const content = state.state === "ready" ? state.content : undefined;
  const [page, setPage] = useState(1);
  const [sheet, setSheet] = useState(0);
  const [row, setRow] = useState(1);
  const [column, setColumn] = useState(1);
  const [mode, setMode] = useState<"grid" | "pages">("grid");
  const pageView = document?.kind === "pages" || mode === "pages";
  const layoutUnavailable =
    document?.kind === "grid" && pageView && document.layout?.state !== "ready";
  const currentSheet =
    document?.sheets.find((value) => value.index === sheet) ??
    document?.sheets.find((value) => !value.hidden) ??
    document?.sheets[0];
  const emptyGrid =
    !pageView &&
    document?.kind === "grid" &&
    (!currentSheet || !currentSheet.rows || !currentSheet.columns);
  const matchesContent =
    content?.state === "ready" &&
    (pageView
      ? content.kind === "page" && content.page === page
      : content.kind === "region" &&
        content.sheet === currentSheet?.index &&
        content.row === row &&
        content.column === column);
  const loading =
    state.state === "loading" ||
    (!emptyGrid &&
      !layoutUnavailable &&
      (content?.state === "loading" ||
        (content?.state === "ready" && !matchesContent)));
  useEffect(() => {
    if (!document) return;
    if (pageView && !layoutUnavailable)
      void preview.read({ kind: "page", page: String(page) });
    else if (
      !pageView &&
      currentSheet &&
      currentSheet.rows > 0 &&
      currentSheet.columns > 0
    )
      void preview.read({
        kind: "region",
        sheet: String(currentSheet.index),
        row: String(row),
        column: String(column),
        rows: String(Math.min(25, currentSheet.rows - row + 1)),
        columns: String(Math.min(10, currentSheet.columns - column + 1)),
      });
  }, [
    preview,
    document?.token,
    pageView,
    layoutUnavailable,
    page,
    currentSheet?.index,
    row,
    column,
  ]);
  const status = state.state === "ready" ? content?.state : state.state;
  const failure =
    status && status !== "ready" && status !== "loading"
      ? (status as DocumentFailure["state"])
      : undefined;
  return (
    <section
      className="document-preview task-panel-resource-view"
      aria-label={title}
      aria-busy={loading}
    >
      <div className="document-preview-toolbar">
        <span>{t("document_preview.readonly")}</span>
        {showRefreshAction && (
          <Button variant="ghost" size="sm" onClick={onRefresh}>
            {t("file_preview.refresh")}
          </Button>
        )}
      </div>
      {document && (
        <>
          {document.kind === "grid" && (
            <div
              className="document-preview-toolbar"
              role="group"
              aria-label={t("document_preview.view")}
            >
              <Button
                variant={!pageView ? "secondary" : "ghost"}
                size="sm"
                aria-pressed={!pageView}
                disabled={loading}
                onClick={() => setMode("grid")}
              >
                {t("document_preview.grid")}
              </Button>
              <Button
                variant={pageView ? "secondary" : "ghost"}
                size="sm"
                aria-pressed={pageView}
                disabled={loading}
                onClick={() => setMode("pages")}
              >
                {t("document_preview.layout")}
              </Button>
            </div>
          )}
          {pageView && !layoutUnavailable ? (
            <nav
              className="document-preview-toolbar"
              aria-label={t("document_preview.pages")}
            >
              <Button
                variant="secondary"
                size="sm"
                disabled={loading || page <= 1}
                onClick={() => setPage(page - 1)}
              >
                {t("document_preview.previous")}
              </Button>
              <span role="status">
                {t("document_preview.page", {
                  current: page,
                  total: document.pageCount,
                })}
              </span>
              <Button
                variant="secondary"
                size="sm"
                disabled={loading || page >= document.pageCount}
                onClick={() => setPage(page + 1)}
              >
                {t("document_preview.next")}
              </Button>
            </nav>
          ) : !pageView ? (
            currentSheet && (
              <>
                <label className="document-preview-sheet">
                  {t("document_preview.sheet")}
                  <select
                    value={currentSheet.index}
                    disabled={loading}
                    onChange={(event) => {
                      setSheet(Number(event.target.value));
                      setRow(1);
                      setColumn(1);
                    }}
                  >
                    {document.sheets.map((value) => (
                      <option key={value.index} value={value.index}>
                        {value.name}
                        {value.hidden
                          ? ` · ${t("document_preview.hidden")}`
                          : ""}
                      </option>
                    ))}
                  </select>
                </label>
                <nav
                  className="document-preview-toolbar"
                  aria-label={t("document_preview.region")}
                >
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={loading || row <= 1}
                    onClick={() => setRow(Math.max(1, row - 25))}
                  >
                    {t("document_preview.previous_rows")}
                  </Button>
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={loading || row + 25 > currentSheet.rows}
                    onClick={() => setRow(row + 25)}
                  >
                    {t("document_preview.next_rows")}
                  </Button>
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={loading || column <= 1}
                    onClick={() => setColumn(Math.max(1, column - 10))}
                  >
                    {t("document_preview.previous_columns")}
                  </Button>
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={loading || column + 10 > currentSheet.columns}
                    onClick={() => setColumn(column + 10)}
                  >
                    {t("document_preview.next_columns")}
                  </Button>
                </nav>
                <p className="document-preview-note">
                  {t("document_preview.saved_values")}
                </p>
              </>
            )
          ) : null}
          {document.kind === "grid" && pageView && !layoutUnavailable && (
            <p className="document-preview-note">
              {t("document_preview.layout_saved_values")}
            </p>
          )}
          <DocumentOmissions
            items={
              pageView && document.kind === "grid"
                ? (document.layout?.omissions ?? [])
                : document.omissions
            }
          />
        </>
      )}
      <div className="document-preview-body">
        {layoutUnavailable ? (
          <p role="status">
            {t(
              document?.layout?.state === "limit"
                ? "document_preview.layout_limit"
                : "document_preview.layout_unsupported",
            )}
          </p>
        ) : loading ? (
          <p role="status">{t("file_preview.loading")}</p>
        ) : failure ? (
          <div role="status">
            <p>{t(`document_preview.state.${failure}`)}</p>
            <Button variant="secondary" size="sm" onClick={onRefresh}>
              {t("file_preview.retry")}
            </Button>
          </div>
        ) : matchesContent &&
          content?.state === "ready" &&
          content.kind === "page" ? (
          <PreviewImageView
            image={content.image}
            alt={t("document_preview.page_alt", { title, page: content.page })}
            onFailure={() => {
              void preview.close();
            }}
          />
        ) : matchesContent &&
          content?.state === "ready" &&
          content.kind === "region" ? (
          <DocumentGrid
            key={`${document?.token}:${content.sheet}:${content.row}:${content.column}`}
            region={content}
          />
        ) : (
          <p role="status">{t("document_preview.empty")}</p>
        )}
      </div>
    </section>
  );
}

function DocumentOmissions({
  items,
}: {
  items: DocumentOpen["omissions"] | DocumentLayout["omissions"];
}) {
  const { t } = useI18n();
  if (!items.length) return null;
  return (
    <p className="document-preview-note">
      {t("document_preview.omissions", {
        items: items
          .map((value) => t(`document_preview.omission.${value}`))
          .join(" · "),
      })}
    </p>
  );
}

function DocumentGrid({ region }: { region: DocumentRegion }) {
  const { t } = useI18n();
  const [selected, setSelected] = useState<DocumentCell | undefined>();
  const descriptionId = useId();
  const cells = new Map(
    region.cells.map((cell) => [`${cell.row}:${cell.column}`, cell]),
  );
  return (
    <>
      <p role="status">
        {columnName(region.column)}
        {region.row}–{columnName(region.column + region.columns - 1)}
        {region.row + region.rows - 1}
      </p>
      <div
        className="document-preview-grid-scroll"
        tabIndex={0}
        aria-label={t("document_preview.region")}
      >
        <table
          className="document-preview-grid"
          aria-label={t("document_preview.grid")}
        >
          <thead>
            <tr>
              <th scope="col">{t("document_preview.row")}</th>
              {Array.from({ length: region.columns }, (_, index) => (
                <th scope="col" key={index}>
                  {columnName(region.column + index)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {Array.from({ length: region.rows }, (_, y) => (
              <tr key={y}>
                <th scope="row">{region.row + y}</th>
                {Array.from({ length: region.columns }, (_, x) => {
                  const cell = cells.get(
                    `${region.row + y}:${region.column + x}`,
                  );
                  const address = `${columnName(region.column + x)}${region.row + y}`;
                  return (
                    <td key={x}>
                      <button
                        type="button"
                        aria-label={address}
                        aria-describedby={descriptionId}
                        aria-pressed={selected === cell && cell !== undefined}
                        style={{
                          fontWeight: cell?.bold ? "bold" : undefined,
                          fontStyle: cell?.italic ? "italic" : undefined,
                          textAlign:
                            cell?.alignment === "right" ||
                            cell?.alignment === "center"
                              ? cell.alignment
                              : "left",
                        }}
                        onClick={() => setSelected(cell)}
                      >
                        {cell?.formula && !cell.value
                          ? t("document_preview.no_cache")
                          : cell?.display || "\u00a0"}
                      </button>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div
        className="document-preview-cell"
        id={descriptionId}
        aria-live="polite"
      >
        {selected ? (
          <dl>
            <dt>{t("document_preview.cell")}</dt>
            <dd>
              {columnName(selected.column)}
              {selected.row}
            </dd>
            <dt>{t("document_preview.formula")}</dt>
            <dd>{selected.formula ?? t("document_preview.none")}</dd>
            <dt>{t("document_preview.saved_value")}</dt>
            <dd>{selected.value?.text ?? t("document_preview.no_cache")}</dd>
            <dt>{t("document_preview.format")}</dt>
            <dd>
              {selected.formatCode}
              {!selected.formatSupported &&
                ` · ${t("document_preview.format_unsupported")}`}
            </dd>
          </dl>
        ) : (
          t("document_preview.select_cell")
        )}
      </div>
    </>
  );
}
