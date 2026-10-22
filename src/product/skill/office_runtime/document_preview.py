"""One-shot, bounded Office preview preparation; never a public file grant.

The controller supplies the same checked private input to text scanning and
rendering/normalization. Host must scan source-text.txt for known credentials
and revalidate source/Task/version/security authority before publishing data.
Raster text is outside this non-OCR scan. PDF uses the separately qualified
reachable-string, metadata and page-text inspector before engine loading.
"""
import datetime
from decimal import Decimal
import hashlib
import json
import math
import posixpath
import re
from pathlib import Path
import tempfile
import zipfile
from urllib.parse import unquote, urlsplit
from xml.sax.handler import ContentHandler

from defusedxml import sax
from office_archive import Limits, checked_copy

TEXT_BYTES = 4 * 1024 * 1024
GRID_BYTES = 8 * 1024 * 1024
PAGE_BYTES = 10 * 1024 * 1024
PAGES_BYTES = 64 * 1024 * 1024
MAX_PAGES = 100
MAX_SHEETS = 64
MAX_ROWS = 10_000
MAX_COLUMNS = 256
MAX_VISITED_CELLS = 100_000
MAX_CELL_BYTES = 32 * 1024
MAX_XML_ELEMENTS = 1_000_000
MAX_MEDIA_PIXELS = 16_777_216


class SourceText(ContentHandler):
    def __init__(self):
        super().__init__()
        self.text = bytearray()
        self.attributes = bytearray()
        self.elements = 0
        self.stack = []
        self.omissions = set()
        self.embedded_count = 0
        self.embedded_bytes = 0
        self.embedded_expanded_bytes = 0
        self.part_names = set()
        self.part_extensions = set()
        self.relationship_base = ""

    def append(self, target, value):
        data = value.encode("utf-8")
        if len(self.text) + len(self.attributes) + len(data) + 1 > TEXT_BYTES:
            raise ValueError("Preview source text budget exceeded")
        target.extend(data)

    def startElement(self, name, attrs):
        self.elements += 1
        self.stack.append(name.rsplit(":", 1)[-1])
        if self.elements > MAX_XML_ELEMENTS or len(self.stack) > 128:
            raise ValueError("Preview XML complexity budget exceeded")
        for value in attrs.values():
            self.append(self.attributes, value + "\n")
        local = self.stack[-1]
        content_type = attrs.get("ContentType", "").lower()
        declared_part_exists = (
            local == "Override" and unquote(attrs.get("PartName", ""), errors="strict").lstrip("/") in self.part_names
            or local == "Default" and attrs.get("Extension", "").lower() in self.part_extensions)
        if declared_part_exists and any(kind in content_type for kind in ("vbaproject", "oleobject", "image/svg+xml")):
            raise ValueError("Preview contains an unsupported content type")
        if local == "Relationship":
            target = unquote(attrs.get("Target", ""), errors="strict")
            uri = urlsplit(target)
            external = attrs.get("TargetMode", "").lower() == "external"
            if external:
                if not attrs.get("Type", "").endswith("/hyperlink"):
                    raise ValueError("Preview cannot load external document resources")
                self.omissions.add("external_hyperlinks")
            elif uri.scheme or uri.netloc or "\\" in target:
                raise ValueError("Preview relationship has an external target")
            else:
                resolved = posixpath.normpath(uri.path.lstrip("/") if uri.path.startswith("/")
                                             else posixpath.join(self.relationship_base, uri.path))
                if resolved == ".." or resolved.startswith("../"):
                    raise ValueError("Preview relationship escapes the package")
        for tag, omission in (("mergeCell", "merged_cells"),
                              ("conditionalFormatting", "conditional_formatting"),
                              ("dataValidation", "data_validation")):
            if local == tag:
                self.omissions.add(omission)

    def endElement(self, name):
        self.stack.pop()

    def characters(self, value):
        # Formatting between XML elements is not displayed document text.
        # Keep whitespace in actual text/value/formula elements. Separate text
        # and attribute streams so formatting properties cannot split a secret
        # which spans multiple Word/PowerPoint text runs.
        if value.strip() or (self.stack and self.stack[-1] in
                             ("t", "delText", "instrText", "v", "f", "text")):
            self.append(self.text, value)


def scan_archive(source, scan, depth=0):
    with zipfile.ZipFile(source) as archive:
        parts = {item.filename for item in archive.infolist() if not item.is_dir()}
        extensions = {Path(part).suffix.lower().lstrip(".") for part in parts}
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = info.filename
            lower = name.lower()
            if "/media/" in lower:
                from PIL import Image
                with archive.open(info) as stream, Image.open(stream) as image:
                    if (image.format not in ("PNG", "JPEG", "GIF", "BMP", "TIFF", "WEBP")
                            or image.width * image.height > MAX_MEDIA_PIXELS):
                        raise ValueError("Preview media is unsupported or exceeds the pixel budget")
                    image.verify()
            if (lower.endswith("vbaproject.bin")
                    or "/activex/" in lower or lower.endswith(".svg")):
                raise ValueError("Preview contains unsupported active or embedded content")
            if "/embeddings/" in lower:
                if not lower.endswith((".xlsx", ".docx", ".pptx")) or depth >= 2:
                    raise ValueError("Preview contains an unsupported embedded object")
                scan.embedded_count += 1
                if scan.embedded_count > 16:
                    raise ValueError("Preview embedded archive count budget exceeded")
                with tempfile.TemporaryDirectory(prefix="metawork-preview-embedded-") as directory:
                    nested = Path(directory) / ("input" + Path(name).suffix)
                    with archive.open(info) as stream, nested.open("xb") as target:
                        copied = 0
                        while chunk := stream.read(64 * 1024):
                            copied += len(chunk)
                            scan.embedded_bytes += len(chunk)
                            if copied > 8 * 1024 * 1024 or scan.embedded_bytes > 16 * 1024 * 1024:
                                raise ValueError("Preview embedded archive byte budget exceeded")
                            target.write(chunk)
                    remaining = 64 * 1024 * 1024 - scan.embedded_expanded_bytes
                    if remaining <= 0:
                        raise ValueError("Preview embedded expansion budget exceeded")
                    limits = Limits(archive_bytes=8 * 1024 * 1024, metadata_bytes=1024 * 1024,
                                    members=1024, member_bytes=min(16 * 1024 * 1024, remaining),
                                    total_bytes=remaining)
                    with checked_copy(nested, limits) as checked:
                        # Canonical checked_copy has verified actual sizes/CRC;
                        # account every expanded member across the nested tree.
                        with zipfile.ZipFile(checked) as verified:
                            scan.embedded_expanded_bytes += sum(item.file_size for item in verified.infolist())
                        scan_archive(checked, scan, depth + 1)
            for prefix, omission in (("xl/charts/", "charts"),
                                     ("xl/media/", "images"),
                                     ("xl/pivottables/", "pivot_tables"),
                                     ("xl/comments", "comments")):
                if lower.startswith(prefix):
                    scan.omissions.add(omission)
            if lower.endswith((".xml", ".rels")):
                scan.part_names = parts
                scan.part_extensions = extensions
                scan.relationship_base = posixpath.dirname(posixpath.dirname(name))
                with archive.open(name) as stream:
                    sax.parse(stream, scan, forbid_dtd=True,
                              forbid_entities=True, forbid_external=True)


def source_text(source):
    scan = SourceText()
    scan_archive(source, scan)
    return bytes(scan.text) + b"\n" + bytes(scan.attributes), sorted(scan.omissions)


def bounded_text(value):
    if len(value.encode("utf-8")) > MAX_CELL_BYTES:
        raise ValueError("Preview cell text budget exceeded")
    return value


def literal(cell):
    value = cell.value
    if value is None:
        return None
    if cell.data_type == "e":
        kind = "error"
    elif isinstance(value, bool):
        kind = "boolean"
        value = "true" if value else "false"
    elif isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        kind = "date"
        value = value.isoformat()
    elif isinstance(value, datetime.timedelta):
        kind = "duration"
        value = str(value.total_seconds())
    elif isinstance(value, (int, float)):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("Preview has a non-finite cell value")
        kind = "number"
    elif isinstance(value, str):
        kind = "text"
    else:
        raise ValueError("Preview has an unsupported cell value")
    return {"kind": kind, "text": bounded_text(str(value))}


def formatted(value, format_code):
    if value is None:
        return "", True
    text = value["text"]
    if format_code in ("General", "@"):
        return text, True
    if value["kind"] != "number":
        # Dates use an explicit ISO representation rather than pretending to
        # reproduce Excel's locale-dependent/custom date format.
        return text, False
    pattern = re.fullmatch(r"([$£€¥]?)(#,##0|0)(?:\.(0{1,8}))?(%?)", format_code)
    if not pattern:
        return text, False
    number = Decimal(text) * (100 if pattern[4] else 1)
    if not number.is_finite():
        raise ValueError("Preview number formatting overflow")
    decimals = len(pattern[3] or "")
    return bounded_text(pattern[1] + format(number, f"{',' if pattern[2] == '#,##0' else ''}.{decimals}f")
                        + pattern[4]), True


def grid(source):
    from openpyxl import load_workbook
    formulas = load_workbook(source, read_only=True, data_only=False, keep_links=False)
    values = None
    try:
        values = load_workbook(source, read_only=True, data_only=True, keep_links=False)
        if len(formulas.worksheets) > MAX_SHEETS:
            raise ValueError("Preview worksheet budget exceeded")
        sheets = []
        visited = 0
        encoded_cells = 0
        for index, sheet in enumerate(formulas.worksheets):
            cached = values[sheet.title]
            # Source dimension metadata can under-report cells. Stream the
            # actual XML once in each formula/value view, never a declared crop.
            sheet.reset_dimensions()
            cached.reset_dimensions()
            rows = sheet.iter_rows()
            cached_rows = cached.iter_rows()
            cells = []
            row_count = column_count = 0
            try:
                for row_index, (row, saved_row) in enumerate(zip(rows, cached_rows, strict=True), 1):
                    visited += len(row)
                    if (row_index > MAX_ROWS or len(row) > MAX_COLUMNS
                            or visited > MAX_VISITED_CELLS):
                        raise ValueError("Preview grid cell/extent budget exceeded")
                    row_count = row_index
                    column_count = max(column_count, len(row))
                    for column, (cell, saved) in enumerate(zip(row, saved_row, strict=True), 1):
                        if cell.value is None and not getattr(cell, "has_style", False):
                            continue
                        formula = cell.value if cell.data_type == "f" else None
                        if formula is not None and not isinstance(formula, str):
                            raise ValueError("Preview does not support this formula representation")
                        value = literal(saved if formula is not None else cell)
                        code = bounded_text(cell.number_format)
                        display, supported = formatted(value, code)
                        entry = {"row": row_index, "column": column,
                                 "formula": bounded_text(formula) if formula is not None else None,
                                 "value": value, "display": display,
                                 "formatCode": code, "formatSupported": supported,
                                 "bold": bool(cell.font.b), "italic": bool(cell.font.i),
                                 "alignment": cell.alignment.horizontal}
                        encoded_cells += len(json.dumps(entry, ensure_ascii=False, allow_nan=False,
                                                        separators=(",", ":")).encode("utf-8")) + 1
                        if encoded_cells > GRID_BYTES:
                            raise ValueError("Preview normalized cell byte budget exceeded")
                        cells.append(entry)
            finally:
                rows.close()
                cached_rows.close()
            sheets.append({"id": str(index + 1), "name": bounded_text(sheet.title),
                           "hidden": sheet.sheet_state != "visible",
                           "rows": row_count, "columns": column_count, "cells": cells})
        return {"schema": 1, "calculation": "saved_values_only", "sheets": sheets}
    finally:
        formulas.close()
        if values is not None:
            values.close()


def write_json(path, value, maximum):
    # Streaming enforces actual encoded bytes without constructing an unbounded
    # second copy of the normalized result. The outer operation owns cleanup.
    length = 0
    with path.open("xb") as stream:
        for item in json.JSONEncoder(ensure_ascii=False, allow_nan=False,
                                     separators=(",", ":")).iterencode(value):
            encoded = item.encode("utf-8")
            length += len(encoded)
            if length > maximum:
                raise ValueError("Preview JSON byte budget exceeded")
            stream.write(encoded)


def resource(path):
    size = path.stat().st_size
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(64 * 1024):
            digest.update(chunk)
    return {"file": path.name, "bytes": size, "sha256": digest.hexdigest()}


def clear_layout(output):
    for index in range(MAX_PAGES):
        (output / f"page-{index + 1:04}.png").unlink(missing_ok=True)
    (output / "pages.json").unlink(missing_ok=True)


def workbook_layout(source, output, width, engine_factory, render, text_bytes):
    from static_workbook import freeze, LayoutUnsupported, LayoutLimit
    from pdf_source import extract, InspectionLimit
    engine = engine_factory()  # construction is inert; reject before entering
    frozen = engine.directory / "static.xlsx"
    try:
        report = freeze(source, frozen)
    except LayoutUnsupported:
        return {"state": "unsupported", "omissions": []}, [], b""
    except LayoutLimit:
        return {"state": "limit", "omissions": []}, [], b""
    try:
        with engine:
            details = render(engine, source, output, width,
                             max_pages=MAX_PAGES, byte_budget=PAGES_BYTES,
                             page_byte_budget=PAGE_BYTES, prepared_layout=(frozen, report))
    except (LayoutUnsupported, LayoutLimit) as failure:
        # Reached only after Engine.__exit__ confirms shutdown; an uncertain
        # shutdown overrides this error and cannot publish a partial result.
        clear_layout(output)
        return {"state": "limit" if isinstance(failure, LayoutLimit) else "unsupported", "omissions": []}, [], b""
    # The engine has settled. Check its actual strings, including number-format
    # literals and chart text, before any page may become a Host resource.
    try:
        converted, _, count = extract(engine.directory / "preview.pdf", TEXT_BYTES - text_bytes - 1)
        if count != details["page_count"]:
            raise ValueError("Workbook inspection and rendering disagree")
    except ValueError as failure:
        clear_layout(output)
        return {"state": "limit" if isinstance(failure, InspectionLimit) else "unsupported", "omissions": []}, [], b""
    omissions = list(report["omissions"])
    if report["removed_defined_names"]:
        omissions.append("defined_names")
    if report["missing_formula_caches"]:
        omissions.append("missing_formula_caches")
    pages = [{**page, **resource(output / page["file"])} for page in
             json.loads((output / "pages.json").read_text(encoding="utf-8"))["pages"]]
    return {"state": "ready", "omissions": sorted(omissions)}, pages, converted


def prepare(source, output, width, engine_factory, render):
    if source.suffix.lower() not in (".docx", ".pptx", ".xlsx", ".pdf"):
        raise ValueError("Preview source text extraction is unavailable for this format")
    expected_pages = None
    scope = "ooxml_xml_text_and_attributes_without_ocr"
    if source.suffix.lower() == ".pdf":
        from pdf_source import extract, SCOPE
        text, omissions, expected_pages = extract(source, TEXT_BYTES)
        scope = SCOPE
    else:
        text, omissions = source_text(source)
    output.mkdir()
    text_path = output / "source-text.txt"
    manifest = {"schema": 1, "format": source.suffix.lower()[1:],
                "textScope": scope,
                "omissions": omissions, "layout": None}
    if source.suffix.lower() == ".xlsx":
        normalized = grid(source)
        grid_path = output / "grid.json"
        write_json(grid_path, normalized, GRID_BYTES)
        manifest.update(kind="grid", grid=resource(grid_path),
                        sheetCount=len(normalized["sheets"]))
        layout, pages, converted = workbook_layout(source, output, width, engine_factory, render, len(text))
        if converted:
            text += b"\n" + converted
        manifest.update(layout=layout, pages=pages,
                        textScope="ooxml_xml_and_available_layout_pdf_text_without_ocr")
        details = {"kind": "grid", "sheet_count": len(normalized["sheets"])}
    else:
        with engine_factory() as engine:
            details = render(engine, source, output, width,
                             max_pages=MAX_PAGES, byte_budget=PAGES_BYTES,
                             page_byte_budget=PAGE_BYTES)
        if expected_pages is not None and details["page_count"] != expected_pages:
            raise ValueError("PDF render and inspection disagree on page count")
        pages = [{**page, **resource(output / page["file"])} for page in
                 json.loads((output / "pages.json").read_text(encoding="utf-8"))["pages"]]
        manifest.update(kind="pages", pages=pages)
        details = {"kind": "pages", **details}
    text_path.write_bytes(text)
    manifest["sourceText"] = resource(text_path)
    write_json(output / "preview.json", manifest, 128 * 1024)
    return details
