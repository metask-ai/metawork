import {
  arrayValue,
  booleanValue,
  enumValue,
  fail,
  nonNegativeNumber,
  object,
  positiveNumber,
  positiveU64WireId,
  record,
  stringValue,
  u64WireInteger,
} from "./wire-codec.ts";

export const documentInvalidatedEvent = "metawork:document-preview-invalidated";
export const documentStates = [
  "busy",
  "missing",
  "restricted",
  "stale_security",
  "unavailable",
  "unsupported",
  "changed",
  "limit",
  "cancelled",
  "expired",
  "restart_required",
  "error",
] as const;
export type DocumentFailure = { state: (typeof documentStates)[number] };
export type DocumentTarget = { kind: "output" | "fileReference"; id: string };
export type DocumentSheet = {
  index: number;
  name: string;
  hidden: boolean;
  rows: number;
  columns: number;
};
export type DocumentOpen = {
  state: "ready";
  generation: string;
  previewId: string;
  token: string;
  securityEpoch: string;
  sourceVersion: string;
  sourceBytes: string;
  idleMs: string;
  lifetimeMs: string;
  format: "docx" | "xlsx" | "pptx";
  kind: "pages" | "grid";
  pageCount: number;
  sheets: DocumentSheet[];
  omissions: string[];
  textScope: string;
};
export type DocumentSelection =
  | { kind: "page"; page: string }
  | {
      kind: "region";
      sheet: string;
      row: string;
      column: string;
      rows: string;
      columns: string;
    };
export type DocumentPage = {
  state: "ready";
  kind: "page";
  readId: string;
  securityEpoch: string;
  transferMs: string;
  image: {
    mediaType: "image/png";
    sizeBytes: string;
    chunkBytes: string;
    width: number;
    height: number;
  };
};
export type DocumentCell = {
  row: number;
  column: number;
  formula: string | null;
  value: {
    kind: "number" | "text" | "boolean" | "date" | "duration" | "error";
    text: string;
  } | null;
  display: string;
  formatCode: string;
  formatSupported: boolean;
  bold: boolean;
  italic: boolean;
  alignment: string | null;
};
export type DocumentRegion = {
  state: "ready";
  kind: "region";
  readId: string;
  securityEpoch: string;
  sheet: number;
  row: number;
  column: number;
  rows: number;
  columns: number;
  cells: DocumentCell[];
};

const omissions = [
  "external_hyperlinks",
  "merged_cells",
  "conditional_formatting",
  "data_validation",
  "charts",
  "images",
  "pivot_tables",
  "comments",
] as const;
const encoder = new TextEncoder();
function text(value: unknown, path: string, maximum: number) {
  const result = stringValue(value, path);
  if (encoder.encode(result).length > maximum)
    fail(path, "text exceeds capacity");
  return result;
}
function hex(value: unknown, path: string, length: number) {
  const result = stringValue(value, path);
  if (result.length !== length || !/^[0-9a-f]+$/.test(result))
    fail(path, "invalid identity");
  return result;
}
function positive(value: unknown, path: string, maximum: number) {
  const result = positiveNumber(value, path);
  if (result > maximum) fail(path, "exceeds capacity");
  return result;
}
function bounded(value: unknown, path: string, maximum: number) {
  const result = nonNegativeNumber(value, path);
  if (result > maximum) fail(path, "exceeds capacity");
  return result;
}
function failure(
  value: Record<string, unknown>,
  path: string,
): DocumentFailure {
  object(value, path, ["state"]);
  return { state: enumValue(value.state, `${path}.state`, documentStates) };
}
export function decodeDocumentOpen(
  value: unknown,
): DocumentOpen | DocumentFailure {
  const path = "document.open";
  const raw = record(value, path);
  if (raw.state !== "ready") return failure(raw, path);
  object(raw, path, [
    "state",
    "generation",
    "previewId",
    "token",
    "securityEpoch",
    "sourceVersion",
    "sourceBytes",
    "idleMs",
    "lifetimeMs",
    "format",
    "kind",
    "pageCount",
    "sheets",
    "omissions",
    "textScope",
  ]);
  const sourceBytes = positiveU64WireId(raw.sourceBytes, `${path}.sourceBytes`);
  if (BigInt(sourceBytes) > 100n * 1024n * 1024n)
    fail(path, "source exceeds capacity");
  const idleMs = positiveU64WireId(raw.idleMs, `${path}.idleMs`);
  const lifetimeMs = positiveU64WireId(raw.lifetimeMs, `${path}.lifetimeMs`);
  if (idleMs !== "120000" || lifetimeMs !== "900000")
    fail(path, "unexpected lease policy");
  const sheets = arrayValue(
    raw.sheets,
    `${path}.sheets`,
    (value, path): DocumentSheet => {
      const sheet = object(value, path, [
        "index",
        "name",
        "hidden",
        "rows",
        "columns",
      ]);
      return {
        index: positive(sheet.index, `${path}.index`, 64),
        name: text(sheet.name, `${path}.name`, 512),
        hidden: booleanValue(sheet.hidden, `${path}.hidden`),
        rows: bounded(sheet.rows, `${path}.rows`, 10000),
        columns: bounded(sheet.columns, `${path}.columns`, 256),
      };
    },
  );
  if (
    sheets.length > 64 ||
    sheets.some((sheet, index) => sheet.index !== index + 1 || !sheet.name)
  )
    fail(path, "invalid worksheet sequence");
  const format = enumValue(raw.format, `${path}.format`, [
    "docx",
    "xlsx",
    "pptx",
  ] as const);
  const kind = enumValue(raw.kind, `${path}.kind`, ["pages", "grid"] as const);
  const pageCount = bounded(raw.pageCount, `${path}.pageCount`, 100);
  if (
    kind === "pages"
      ? pageCount === 0 || sheets.length !== 0 || format === "xlsx"
      : pageCount !== 0 || format !== "xlsx"
  )
    fail(path, "inconsistent document variant");
  const omitted = arrayValue(raw.omissions, `${path}.omissions`, (item, path) =>
    enumValue(item, path, omissions),
  );
  if (omitted.length > 16 || new Set(omitted).size !== omitted.length)
    fail(path, "invalid omission list");
  const textScope = stringValue(raw.textScope, `${path}.textScope`);
  if (textScope !== "ooxml_xml_text_and_attributes_without_ocr")
    fail(path, "unsupported text scope");
  const sourceVersion = hex(raw.sourceVersion, `${path}.sourceVersion`, 64);
  if (/^0+$/.test(sourceVersion)) fail(path, "invalid source version");
  return {
    state: "ready",
    generation: positiveU64WireId(raw.generation, `${path}.generation`),
    previewId: positiveU64WireId(raw.previewId, `${path}.previewId`),
    token: hex(raw.token, `${path}.token`, 48),
    securityEpoch: positiveU64WireId(
      raw.securityEpoch,
      `${path}.securityEpoch`,
    ),
    sourceVersion,
    sourceBytes,
    idleMs,
    lifetimeMs,
    format,
    kind,
    pageCount,
    sheets,
    omissions: omitted,
    textScope,
  };
}
function cell(value: unknown, path: string): DocumentCell {
  const raw = object(value, path, [
    "row",
    "column",
    "formula",
    "value",
    "display",
    "formatCode",
    "formatSupported",
    "bold",
    "italic",
    "alignment",
  ]);
  let cached: DocumentCell["value"] = null;
  if (raw.value !== null) {
    const value = object(raw.value, `${path}.value`, ["kind", "text"]);
    cached = {
      kind: enumValue(value.kind, `${path}.value.kind`, [
        "number",
        "text",
        "boolean",
        "date",
        "duration",
        "error",
      ] as const),
      text: text(value.text, `${path}.value.text`, 32768),
    };
  }
  return {
    row: positive(raw.row, `${path}.row`, 10000),
    column: positive(raw.column, `${path}.column`, 256),
    formula:
      raw.formula === null ? null : text(raw.formula, `${path}.formula`, 32768),
    value: cached,
    display: text(raw.display, `${path}.display`, 32768),
    formatCode: text(raw.formatCode, `${path}.formatCode`, 32768),
    formatSupported: booleanValue(
      raw.formatSupported,
      `${path}.formatSupported`,
    ),
    bold: booleanValue(raw.bold, `${path}.bold`),
    italic: booleanValue(raw.italic, `${path}.italic`),
    alignment:
      raw.alignment === null
        ? null
        : text(raw.alignment, `${path}.alignment`, 32768),
  };
}
export function decodeDocumentRead(
  value: unknown,
): DocumentPage | DocumentRegion | DocumentFailure {
  const path = "document.read";
  const raw = record(value, path);
  if (raw.state !== "ready") return failure(raw, path);
  const readId = positiveU64WireId(raw.readId, `${path}.readId`);
  const securityEpoch = positiveU64WireId(
    raw.securityEpoch,
    `${path}.securityEpoch`,
  );
  if (raw.kind === "page") {
    object(raw, path, [
      "state",
      "kind",
      "readId",
      "securityEpoch",
      "transferMs",
      "image",
    ]);
    const image = object(raw.image, `${path}.image`, [
      "mediaType",
      "sizeBytes",
      "chunkBytes",
      "width",
      "height",
    ]);
    if (
      image.mediaType !== "image/png" ||
      image.chunkBytes !== "262143" ||
      raw.transferMs !== "15000"
    )
      fail(path, "unsupported image transport");
    const sizeBytes = positiveU64WireId(
      image.sizeBytes,
      `${path}.image.sizeBytes`,
    );
    const width = positive(image.width, `${path}.image.width`, 8192);
    const height = positive(image.height, `${path}.image.height`, 8192);
    if (BigInt(sizeBytes) > 10n * 1024n * 1024n || width * height > 4000000)
      fail(path, "image exceeds capacity");
    return {
      state: "ready",
      kind: "page",
      readId,
      securityEpoch,
      transferMs: "15000",
      image: {
        mediaType: "image/png",
        sizeBytes,
        chunkBytes: "262143",
        width,
        height,
      },
    };
  }
  object(raw, path, [
    "state",
    "kind",
    "readId",
    "securityEpoch",
    "sheet",
    "row",
    "column",
    "rows",
    "columns",
    "cells",
  ]);
  if (raw.kind !== "region") fail(path, "unsupported selection");
  const sheet = positive(raw.sheet, `${path}.sheet`, 64);
  const row = positive(raw.row, `${path}.row`, 10000);
  const column = positive(raw.column, `${path}.column`, 256);
  const rows = positive(raw.rows, `${path}.rows`, 100);
  const columns = positive(raw.columns, `${path}.columns`, 20);
  if (rows * columns > 500 || row + rows > 10001 || column + columns > 257)
    fail(path, "invalid region");
  const cells = arrayValue(raw.cells, `${path}.cells`, cell);
  if (cells.length > 500) fail(path, "cell capacity exceeded");
  let position = 0;
  for (const item of cells) {
    const next = item.row * 257 + item.column;
    if (
      next <= position ||
      item.row < row ||
      item.row >= row + rows ||
      item.column < column ||
      item.column >= column + columns
    )
      fail(path, "invalid cell order or position");
    position = next;
  }
  return {
    state: "ready",
    kind: "region",
    readId,
    securityEpoch,
    sheet,
    row,
    column,
    rows,
    columns,
    cells,
  };
}
export function decodeDocumentChunk(value: unknown) {
  const path = "document.chunk";
  const raw = record(value, path);
  if (raw.state !== "ready") return failure(raw, path);
  object(raw, path, ["state", "readId", "offset", "bytes", "dataBase64"]);
  const bytes = positiveU64WireId(raw.bytes, `${path}.bytes`);
  if (BigInt(bytes) > 262143n) fail(path, "chunk exceeds capacity");
  const dataBase64 = stringValue(raw.dataBase64, `${path}.dataBase64`);
  if (
    dataBase64.length !== Math.ceil(Number(bytes) / 3) * 4 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(dataBase64)
  )
    fail(path, "invalid chunk encoding");
  return {
    state: "ready" as const,
    readId: positiveU64WireId(raw.readId, `${path}.readId`),
    offset: u64WireInteger(raw.offset, `${path}.offset`),
    bytes,
    dataBase64,
  };
}
export function decodeDocumentClose(value: unknown) {
  const path = "document.close";
  const raw = record(value, path);
  if (raw.state !== "ready" && raw.state !== "restart_required")
    return failure(raw, path);
  object(raw, path, ["state", "generation", "previewId", "released"]);
  if (raw.released !== (raw.state === "ready"))
    fail(path, "inconsistent cleanup result");
  return {
    state: raw.state as "ready" | "restart_required",
    generation: positiveU64WireId(raw.generation, `${path}.generation`),
    previewId: positiveU64WireId(raw.previewId, `${path}.previewId`),
    released: raw.released as boolean,
  };
}
export function decodeDocumentReleaseRead(value: unknown) {
  const path = "document.releaseRead";
  const raw = record(value, path);
  if (raw.state !== "ready") return failure(raw, path);
  object(raw, path, ["state", "readId", "released"]);
  if (raw.released !== true) fail(path, "read was not released");
  return {
    state: "ready" as const,
    readId: positiveU64WireId(raw.readId, `${path}.readId`),
    released: true as const,
  };
}
export function decodeDocumentInvalidated(value: unknown) {
  const path = "document.invalidated";
  const raw = object(value, path, [
    "generation",
    "previewId",
    "token",
    "reason",
  ]);
  return {
    generation: positiveU64WireId(raw.generation, `${path}.generation`),
    previewId: positiveU64WireId(raw.previewId, `${path}.previewId`),
    token: hex(raw.token, `${path}.token`, 48),
    reason: enumValue(raw.reason, `${path}.reason`, documentStates),
  };
}
