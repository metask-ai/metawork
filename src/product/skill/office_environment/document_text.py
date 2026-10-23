"""Bounded structured OOXML text, preserving revision and worksheet context.

The caller supplies a private archive whose full payloads have been checked.
No OCR, external resources, macros or document-supplied code are executed.
"""
import json
import posixpath
import zipfile
from defusedxml import ElementTree as ET

WORD = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
DRAWING = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
PRESENTATION = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"


def word_runs(element, revision=None):
    if element.tag in (WORD + "ins", WORD + "del", WORD + "moveFrom", WORD + "moveTo"):
        revision = element.tag.removeprefix(WORD)
    if element.tag in (WORD + "t", WORD + "delText"):
        yield {"text": element.text or "", "revision": revision}
    elif element.tag == WORD + "tab":
        yield {"text": "\t", "revision": revision}
    elif element.tag in (WORD + "br", WORD + "cr"):
        yield {"text": "\n", "revision": revision}
    for child in element:
        yield from word_runs(child, revision)


def word_blocks(element):
    for child in element:
        if child.tag == WORD + "p":
            yield {"paragraph": list(word_runs(child))}
        elif child.tag == WORD + "tbl":
            yield {"table": [[list(word_blocks(cell)) for cell in row.findall(WORD + "tc")]
                             for row in child.findall(WORD + "tr")]}
        else:
            yield from word_blocks(child)


def extract(path, output):
    suffix = path.suffix.lower()
    if suffix == ".xlsx":
        from openpyxl import load_workbook
        formulas = load_workbook(path, read_only=True, data_only=False)
        values = load_workbook(path, read_only=True, data_only=True)
        try:
            sheets = []
            budget = 1_000_000
            for sheet in formulas:
                budget -= sheet.max_row * sheet.max_column
                if budget < 0:
                    raise ValueError("Workbook text cell budget exceeded")
                cells = []
                for row, cached_row in zip(sheet.iter_rows(), values[sheet.title].iter_rows(), strict=True):
                    for cell, cached in zip(row, cached_row, strict=True):
                        if cell.value is not None:
                            cells.append({"cell": cell.coordinate, "value": str(cell.value),
                                          "formula": cell.data_type == "f",
                                          "cached": str(cached.value) if cached.value is not None else None})
                sheets.append({"name": sheet.title, "rows": sheet.max_row, "columns": sheet.max_column,
                               "cells": cells})
            result = {"format": "xlsx", "sheets": sheets}
        finally:
            formulas.close()
            values.close()
    else:
        with zipfile.ZipFile(path) as archive:
            if suffix == ".docx":
                parts = []
                for name in archive.namelist():
                    if (name == "word/document.xml" or name.startswith(("word/header", "word/footer"))
                            or name in ("word/footnotes.xml", "word/endnotes.xml", "word/comments.xml")) and name.endswith(".xml"):
                        parts.append({"part": name, "blocks": list(word_blocks(ET.fromstring(archive.read(name))))})
                result = {"format": "docx", "parts": parts}
            elif suffix == ".pptx":
                presentation = ET.fromstring(archive.read("ppt/presentation.xml"))
                relationships = ET.fromstring(archive.read("ppt/_rels/presentation.xml.rels"))
                targets = {entry.get("Id"): entry for entry in relationships}
                slides = []
                for item in presentation.findall(".//" + PRESENTATION + "sldId"):
                    relationship = targets[item.get(REL + "id")]
                    name = posixpath.normpath("ppt/" + relationship.get("Target", ""))
                    if (relationship.get("TargetMode") == "External" or not name.startswith("ppt/slides/")
                            or name.count("/") != 2 or not name.endswith(".xml")):
                        raise ValueError("Invalid presentation slide relationship")
                    slide = ET.fromstring(archive.read(name))
                    slides.append({"part": name, "hidden": slide.get("show") in ("0", "false"),
                                   "paragraphs": ["".join(node.text or "" for node in paragraph.iter(DRAWING + "t"))
                                                  for paragraph in slide.iter(DRAWING + "p")]})
                notes = [{"part": name, "text": "\n".join(node.text or "" for node in ET.fromstring(archive.read(name)).iter(DRAWING + "t"))}
                         for name in archive.namelist() if name.startswith("ppt/notesSlides/notesSlide") and name.endswith(".xml")]
                result = {"format": "pptx", "slides": slides, "notes": notes}
            else:
                raise ValueError("Structured text requires DOCX, XLSX or PPTX")
    encoded = json.dumps(result, ensure_ascii=False).encode("utf-8")
    if len(encoded) > 4 * 1024 * 1024:
        raise ValueError("Document text byte budget exceeded; unpack and inspect selected XML parts instead")
    output.write_bytes(encoded)
    return {"format": suffix.removeprefix("."), "text_bytes": len(encoded)}
