"""Bounded assertions over saved XLSX bytes; no formula evaluation or editing.

Usage: <Skill run entry> python verify.py candidate.xlsx report.json [--checks checks.json]
Exit: 0 completed checks, 1 assertions failed, 2 invalid specification,
3 required checks incomplete/unsupported, 4 execution or report error.
The JSON report is the interface; stdout contains no workbook values.
"""
import argparse
from contextlib import ExitStack
from dataclasses import replace
from datetime import date, datetime
import hashlib
import json
import math
import os
from pathlib import Path
import posixpath
import re
import stat
import sys
import time
import warnings
import zipfile
from urllib.parse import unquote, urlsplit

from defusedxml import ElementTree as ET
from openpyxl import load_workbook
from openpyxl.cell.read_only import EMPTY_CELL
from openpyxl.utils.cell import get_column_letter, range_boundaries
from office_archive import checked_copy, DEFAULT_LIMITS

MAX_SPEC = 256 * 1024
MAX_REPORT = 512 * 1024
MAX_CHECKS = 128
MAX_CELLS = 200_000
MAX_NODES = 600_000
MAX_SECONDS = 60
LIMITS = replace(DEFAULT_LIMITS, archive_bytes=32 * 1024 * 1024,
                 member_bytes=16 * 1024 * 1024, total_bytes=64 * 1024 * 1024)
SML = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"
DOC_REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
OPERATIONS = {"sheets", "values", "label", "count", "font", "fill", "number_format", "unchanged", "unsupported"}


class SpecError(ValueError):
    pass


class BudgetError(ValueError):
    pass


class Unsupported(ValueError):
    pass


class MissingTarget(ValueError):
    pass


class Budget:
    def __init__(self):
        self.deadline = time.monotonic() + MAX_SECONDS
        self.cells = 0

    def tick(self, cells=0):
        self.cells += cells
        if self.cells > MAX_CELLS or time.monotonic() > self.deadline:
            raise BudgetError("Check traversal/time budget exceeded")


def fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise SpecError("Invalid fields")


def string(value, limit=1024):
    if not isinstance(value, str) or not value or len(value) > limit:
        raise SpecError("Invalid string")
    return value


def integer(value, low=0, high=MAX_CELLS):
    if type(value) is not int or not low <= value <= high:
        raise SpecError("Invalid integer")
    return value


def number(value):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise SpecError("Invalid finite number")
    return value


def bounds(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Z]{1,3}[1-9][0-9]{0,6}(?::[A-Z]{1,3}[1-9][0-9]{0,6})?", value):
        raise SpecError("Use an explicit A1 cell or rectangle")
    a, b, c, d = range_boundaries(value)
    if not (1 <= a <= c <= 16384 and 1 <= b <= d <= 1048576) or (c - a + 1) * (d - b + 1) > MAX_CELLS:
        raise SpecError("Selector outside format/traversal budget")
    return a, b, c, d


def typed(value):
    fields(value, ("type",), ("value", "tolerance"))
    kind = value["type"]
    if not isinstance(kind, str):
        raise SpecError("Invalid value type")
    if kind == "blank":
        fields(value, ("type",))
    elif kind == "number":
        fields(value, ("type", "value", "tolerance"))
        number(value["value"])
        if number(value["tolerance"]) < 0:
            raise SpecError("Negative tolerance")
    elif kind in ("string", "formula", "date", "datetime", "error"):
        fields(value, ("type", "value"))
        if not isinstance(value["value"], str) or len(value["value"]) > 4096:
            raise SpecError("Invalid expected string")
        if kind == "formula" and not value["value"].startswith("="):
            raise SpecError("Expected formula text")
        if kind in ("date", "datetime"):
            try:
                (date if kind == "date" else datetime).fromisoformat(value["value"])
            except ValueError as error:
                raise SpecError("Invalid ISO date") from error
    elif kind == "boolean":
        fields(value, ("type", "value"))
        if type(value["value"]) is not bool:
            raise SpecError("Invalid boolean")
    else:
        raise SpecError("Unknown value type")


def target_spec(target):
    fields(target, ("sheet",), ("range", "label", "offset", "size"))
    string(target["sheet"], 31)
    if "range" in target:
        fields(target, ("sheet", "range"))
        bounds(target["range"])
    else:
        fields(target, ("sheet", "label"), ("offset", "size"))
        fields(target["label"], ("range", "value"))
        bounds(target["label"]["range"])
        string(target["label"]["value"])
        for key, default in (("offset", [0, 0]), ("size", [1, 1])):
            values = target.get(key, default)
            if not isinstance(values, list) or len(values) != 2:
                raise SpecError("Expected row/column pair")
            for value in values:
                integer(value, -1048576 if key == "offset" else 1, 1048576)
        height, width = target.get("size", [1, 1])
        if height * width > MAX_CELLS:
            raise SpecError("Selector budget exceeded")


def style_spec(op, expected):
    if op == "number_format":
        string(expected)
        return
    allowed = {"name", "size", "bold", "italic", "color"} if op == "font" else {"pattern", "color"}
    fields(expected, (), allowed)
    if not expected:
        raise SpecError("Empty style assertion")
    for key, value in expected.items():
        if key in ("bold", "italic"):
            if type(value) is not bool:
                raise SpecError("Expected style boolean")
        elif key == "size":
            if number(value) <= 0:
                raise SpecError("Invalid font size")
        elif key == "color":
            if not isinstance(value, str) or not re.fullmatch("[0-9A-F]{8}", value):
                raise SpecError("Use explicit eight-digit ARGB")
        else:
            string(value)


def parse_spec(path):
    if path is None:
        return None
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    with os.fdopen(os.open(path, flags), "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise OSError("Check specification must be a regular file")
        if before.st_size > MAX_SPEC:
            raise SpecError("Specification byte budget exceeded")
        data = source.read(MAX_SPEC + 1)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise OSError("Check specification changed while reading")
    if len(data) > MAX_SPEC:
        raise SpecError("Specification byte budget exceeded")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise SpecError("Duplicate specification field")
            result[key] = value
        return result
    try:
        spec = json.loads(data, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(SpecError("Nonfinite JSON")))
    except (ValueError, RecursionError) as error:
        raise SpecError("Invalid specification JSON") from error
    fields(spec, ("version", "checks", "requirements"))
    if type(spec["version"]) is not int or spec["version"] != 1:
        raise SpecError("Unsupported specification version")
    checks, requirements = spec["checks"], spec["requirements"]
    if not isinstance(checks, list) or len(checks) > MAX_CHECKS or not isinstance(requirements, list) or len(requirements) > MAX_CHECKS:
        raise SpecError("Check/requirement budget exceeded")
    ids = set()
    for check in checks:
        fields(check, ("id", "op"), ("target", "expected", "original", "properties", "reason"))
        identity, op = string(check["id"], 80), check["op"]
        if identity in ids or not isinstance(op, str) or op not in OPERATIONS:
            raise SpecError("Duplicate check or unknown operation")
        ids.add(identity)
        if op == "unsupported":
            fields(check, ("id", "op", "reason"))
            string(check["reason"])
            continue
        if op == "sheets":
            fields(check, ("id", "op", "expected"))
            if not isinstance(check["expected"], list) or not check["expected"] or len(check["expected"]) > 64:
                raise SpecError("Expected ordered sheet list")
            for name in check["expected"]:
                string(name, 31)
            if len(set(check["expected"])) != len(check["expected"]):
                raise SpecError("Duplicate sheet expectation")
            continue
        required = ("id", "op", "target", "original", "properties") if op == "unchanged" else ("id", "op", "target", "expected")
        fields(check, required)
        target_spec(check["target"])
        if op == "values":
            matrix = check["expected"]
            if not isinstance(matrix, list) or not matrix or not all(isinstance(row, list) and row for row in matrix):
                raise SpecError("Expected nonempty typed matrix")
            dims = (len(matrix), len(matrix[0]))
            if any(len(row) != dims[1] for row in matrix) or dims[0] * dims[1] > MAX_CELLS:
                raise SpecError("Invalid matrix dimensions")
            if "range" in check["target"]:
                a, b, c, d = bounds(check["target"]["range"])
                shape = (d - b + 1, c - a + 1)
            else:
                shape = tuple(check["target"].get("size", [1, 1]))
            if dims != shape:
                raise SpecError("Expected values must cover the entire target")
            for row in matrix:
                for value in row:
                    typed(value)
        elif op == "label":
            fields(check["expected"], ("value", "cell"))
            string(check["expected"]["value"])
            a, b, c, d = bounds(check["expected"]["cell"])
            if a != c or b != d:
                raise SpecError("Expected a single label coordinate")
        elif op == "count":
            integer(check["expected"])
        elif op == "unchanged":
            string(check["original"], 4096)
            props = check["properties"]
            if not isinstance(props, list) or not props or any(p not in ("value", "font", "fill", "number_format") for p in props):
                raise SpecError("Unknown preservation property")
        else:
            style_spec(op, check["expected"])
    requirement_ids = set()
    for requirement in requirements:
        fields(requirement, ("id", "source", "checks"), ("required",))
        identity = string(requirement["id"], 80)
        if identity in requirement_ids:
            raise SpecError("Duplicate requirement")
        requirement_ids.add(identity)
        string(requirement["source"], 4096)
        if type(requirement.get("required", True)) is not bool:
            raise SpecError("Expected required boolean")
        refs = requirement["checks"]
        if not isinstance(refs, list) or any(not isinstance(ref, str) or ref not in ids for ref in refs):
            raise SpecError("Invalid requirement/check mapping")
    return spec


def fingerprint(path):
    stat = Path(path).lstat()
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            result.update(chunk)
    return {"bytes": Path(path).stat().st_size, "sha256": result.hexdigest()}


def preflight(path, budget):
    """Bound XML/library inputs before openpyxl creates shared strings/styles.

    This is an allocation guard, not another schema validator. Only bounded
    worksheet geometry is retained; cell values/styles are read by openpyxl.
    """
    geometry, names = {}, None
    with zipfile.ZipFile(path) as archive:
        entries = set(archive.namelist())
        if not {"[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"} <= entries:
            raise ValueError("Missing XLSX package parts")
        if any(name.lower().endswith("vbaproject.bin") for name in entries):
            raise Unsupported("Macro-bearing workbook")
        nodes = 0
        book_sheets, book_rels, main_relationships, style_nodes = [], {}, 0, 0
        for name in sorted(entries):
            if not name.endswith((".xml", ".rels")):
                continue
            conditional, merged, depth = [], [], 0
            relation_ids = set()
            with archive.open(name) as source:
                for event, element in ET.iterparse(source, events=("start", "end"), forbid_dtd=True):
                    if event == "start":
                        nodes += 1
                        depth += 1
                        if nodes > MAX_NODES or depth > 128:
                            raise BudgetError("XML node/depth budget exceeded")
                        if nodes % 1024 == 0:
                            budget.tick()
                        if name == "xl/styles.xml" and element.tag in (SML + "xf", SML + "font", SML + "fill", SML + "border"):
                            style_nodes += 1
                            if style_nodes > 10_000:
                                raise BudgetError("Style allocation budget exceeded")
                        if element.tag == SML + "c":
                            a, b, c, d = bounds(element.get("r", ""))
                            if c * d > MAX_CELLS:
                                raise BudgetError("Sparse worksheet extent budget exceeded")
                        if element.tag == SML + "dimension":
                            # A sparse million-row sheet must not induce dense
                            # iteration, even for a seemingly small check.
                            try:
                                a, b, c, d = bounds(element.get("ref", ""))
                                if c * d > MAX_CELLS:
                                    raise BudgetError("Sparse worksheet extent budget exceeded")
                            except SpecError as error:
                                raise BudgetError("Worksheet dimension budget exceeded") from error
                        if element.tag == SML + "conditionalFormatting":
                            conditional.extend(element.get("sqref", "").split())
                        if element.tag == SML + "mergeCell":
                            merged.append(element.get("ref", ""))
                        if name.endswith(".rels") and element.tag == REL + "Relationship":
                            identity = element.get("Id")
                            if not identity or identity in relation_ids:
                                raise ValueError("Invalid relationship identity")
                            relation_ids.add(identity)
                            target = None
                            if element.get("TargetMode") != "External":
                                directory = posixpath.dirname(posixpath.dirname(name)) if name != "_rels/.rels" else ""
                                parsed_target = urlsplit(element.get("Target", ""))
                                if parsed_target.scheme or parsed_target.netloc or parsed_target.query:
                                    raise ValueError("Invalid internal relationship URI")
                                raw_target = unquote(parsed_target.path)
                                target = posixpath.normpath(raw_target.lstrip("/") if raw_target.startswith("/") else posixpath.join(directory, raw_target))
                                if not raw_target or target not in entries:
                                    raise ValueError("Missing internal relationship target")
                            if name == "_rels/.rels" and element.get("Type") == DOC_REL[1:-1] + "/officeDocument":
                                main_relationships += 1
                                if target != "xl/workbook.xml" or element.get("TargetMode") == "External":
                                    raise Unsupported("Noncanonical workbook part")
                        if name == "xl/workbook.xml" and element.tag == SML + "sheet":
                            if len(book_sheets) >= 64:
                                raise BudgetError("Sheet allocation budget exceeded")
                            book_sheets.append((element.get("name"), element.get(DOC_REL + "id")))
                        if name == "xl/_rels/workbook.xml.rels" and element.tag == REL + "Relationship":
                            identity = element.get("Id")
                            if len(book_rels) >= 4096:
                                raise BudgetError("Relationship allocation budget exceeded")
                            if identity in book_rels:
                                raise ValueError("Duplicate workbook relationship")
                            book_rels[identity] = dict(element.attrib)
                    else:
                        depth -= 1
                        element.clear()
            geometry[name] = (conditional, merged)
        if main_relationships != 1:
            raise ValueError("Missing/ambiguous main workbook relationship")
        if not 1 <= len(book_sheets) <= 64:
            raise Unsupported("Unsupported sheet namespace or count")
        names = [name for name, _ in book_sheets]
        if any(not isinstance(name, str) for name in names) or len(set(names)) != len(names):
            raise ValueError("Invalid sheet names")
        per_sheet = {}
        for name, identity in book_sheets:
            relation = book_rels.get(identity, {})
            raw_target = unquote(urlsplit(relation.get("Target", "")).path)
            target = posixpath.normpath(posixpath.join("xl", raw_target).lstrip("/"))
            if relation.get("Target", "").startswith("/"):
                target = posixpath.normpath(raw_target.lstrip("/"))
            if relation.get("TargetMode") == "External" or target not in entries:
                raise ValueError("Missing/internal worksheet relationship")
            if relation.get("Type") != DOC_REL[1:-1] + "/worksheet":
                raise Unsupported("Non-worksheet sheet")
            per_sheet[name] = geometry.get(target, ([], []))
    return names, per_sheet


def opened(stack, path, budget, candidate_report=None):
    before = fingerprint(path)
    checked = stack.enter_context(checked_copy(path, LIMITS))
    if candidate_report is not None:
        candidate_report["candidate"] = digest(checked)
    names, geometry = preflight(checked, budget)
    with warnings.catch_warnings():
        # Library warning strings are not a safe stdout/stderr channel for
        # document content. Unsupported scopes are reported explicitly below.
        warnings.simplefilter("ignore")
        book = load_workbook(checked, read_only=True, data_only=False, keep_links=False)
    stack.callback(book.close)
    budget.tick()
    if book.sheetnames != names:
        raise ValueError("Workbook sheets were not all loaded")
    return book, geometry, before


def cells(sheet, rectangle, budget):
    a, b, c, d = rectangle
    budget.tick((c - a + 1) * (d - b + 1))
    result = []
    # Explicit bounds produce cells even beyond the used area: missing targets
    # remain assertions, rather than an empty loop that could pass.
    row_index = b - 1
    for row_index, row in enumerate(sheet.iter_rows(min_row=b, max_row=d, min_col=a, max_col=c), b):
        budget.tick()
        result.extend((f"{get_column_letter(column)}{row_index}", cell) for column, cell in enumerate(row, a))
    # ReadOnlyWorksheet returns no rows at all when the requested start lies
    # beyond the final stored row. Explicit blanks preserve selector cardinality.
    for missing_row in range(row_index + 1, d + 1):
        budget.tick()
        result.extend((f"{get_column_letter(column)}{missing_row}", EMPTY_CELL) for column in range(a, c + 1))
    if len(result) != (c - a + 1) * (d - b + 1):
        raise RuntimeError("Incomplete worksheet traversal")
    return result


def select(book, target, budget):
    name = target["sheet"]
    if name not in book.sheetnames:
        raise MissingTarget("missing_sheet")
    sheet = book[name]
    if "range" in target:
        rectangle = bounds(target["range"])
    else:
        label = target["label"]
        matches = [coordinate for coordinate, cell in cells(sheet, bounds(label["range"]), budget)
                   if cell.value == label["value"] and cell.data_type != "f"]
        if len(matches) != 1:
            raise MissingTarget("label_missing" if not matches else "label_ambiguous")
        a, b, _, _ = bounds(matches[0])
        dy, dx = target.get("offset", [0, 0])
        height, width = target.get("size", [1, 1])
        a, b = a + dx, b + dy
        if not (1 <= a <= a + width - 1 <= 16384 and 1 <= b <= b + height - 1 <= 1048576):
            raise SpecError("Resolved selector outside format")
        rectangle = a, b, a + width - 1, b + height - 1
    return rectangle, cells(sheet, rectangle, budget)


def actual_value(cell):
    value = cell.value
    if value is None:
        return {"type": "blank"}
    if cell.data_type in ("f", "e"):
        return {"type": "formula" if cell.data_type == "f" else "error", "value": value}
    if isinstance(value, datetime):
        return {"type": "datetime", "value": value.isoformat()}
    if isinstance(value, date):
        return {"type": "date", "value": value.isoformat()}
    kind = {bool: "boolean", int: "number", float: "number", str: "string"}.get(type(value))
    if kind is None or kind == "number" and not math.isfinite(value):
        raise Unsupported("Unrepresented saved value")
    return {"type": kind, "value": value}


def value_matches(actual, expected):
    if actual["type"] != expected["type"]:
        return False
    if actual["type"] == "number":
        return abs(actual["value"] - expected["value"]) <= expected["tolerance"]
    return actual == expected


def intersects(first, second):
    a, b, c, d = first
    e, f, g, h = second
    return a <= g and e <= c and b <= h and f <= d


def style_supported(rectangle, geometry):
    conditional, merged = geometry
    for item in conditional + merged:
        # Whole row/column and other unrepresented geometry is unsupported.
        try:
            overlap = intersects(rectangle, bounds(item))
        except SpecError:
            overlap = True
        if overlap:
            raise Unsupported("Conditional or merged-cell style scope")


def color(value):
    if value is None:
        return None
    if value.type != "rgb" or value.tint != 0:
        raise Unsupported("Theme/indexed/tinted style color")
    return value.rgb.upper()


def style_value(cell, op, keys=None):
    if op == "number_format":
        return cell.number_format
    if op == "font":
        font = cell.font
        if keys is None:
            return {key: color(font.color) if key == "color" else getattr(font, key)
                    for key in font.__attrs__ + font.__elements__} if font else None
        values = {"name": font.name if font else None, "size": font.sz if font else None,
                  "bold": bool(font.b) if font else False, "italic": bool(font.i) if font else False}
        if keys is None or "color" in keys:
            values["color"] = color(font.color if font else None)
    else:
        fill = cell.fill
        if fill is not None and getattr(fill, "patternType", "unsupported") not in (None, "solid"):
            raise Unsupported("Non-solid fill")
        values = {"pattern": fill.patternType if fill else None}
        if keys is None or "color" in keys:
            values["color"] = color(fill.fgColor if fill else None)
        if keys is None:
            values["background_color"] = color(fill.bgColor if fill else None)
    return {key: values[key] for key in keys} if keys is not None else values


def detail(value):
    """Bound individual values without pretending truncated detail is complete."""
    encoded = json.dumps(value, ensure_ascii=True, allow_nan=False)
    return value if len(encoded) <= 4096 else {"detail_omitted": True}


def omitted(value):
    if isinstance(value, dict):
        return value.get("detail_omitted") is True or value.get("details_truncated") is True or any(omitted(item) for item in value.values())
    if isinstance(value, list):
        return any(omitted(item) for item in value)
    return False


def evaluate(check, book, geometry, references, budget):
    op = check["op"]
    result = {"id": check["id"], "op": op, "status": "passed"}
    if "expected" in check:
        # The entire specification is already bounded. Preserve ordinary large
        # matrices rather than truncating a successful check unnecessarily.
        result["expected"] = check["expected"]
    if "target" in check:
        result["target"] = check["target"]
    try:
        if op == "unsupported":
            raise Unsupported(check["reason"])
        if op == "sheets":
            result["actual"] = book.sheetnames
            if book.sheetnames != check["expected"]:
                result["status"] = "failed"
            return result
        rectangle, selected = select(book, check["target"], budget)
        result["matched_cells"] = len(selected)
        result["nonempty_cells"] = sum(cell.value is not None for _, cell in selected)
        if op == "label":
            matches = [coordinate for coordinate, cell in selected if cell.value == check["expected"]["value"] and cell.data_type != "f"]
            result["actual"] = {"count": len(matches), "cells": matches[:20]}
            result["status"] = "passed" if matches == [check["expected"]["cell"]] else "failed"
            return result
        if op == "count":
            result["actual"] = result["nonempty_cells"]
            result["status"] = "passed" if result["actual"] == check["expected"] else "failed"
            return result
        if op in ("font", "fill", "number_format"):
            if not result["nonempty_cells"]:
                raise MissingTarget("empty_style_scope")
            style_supported(rectangle, geometry[check["target"]["sheet"]])
        original = None
        if op == "unchanged":
            original, original_geometry, _ = references[check["original"]]
            original_rect, original_cells = select(original, check["target"], budget)
            if original_rect != rectangle:
                raise MissingTarget("preserved_target_moved")
            if any(prop != "value" for prop in check["properties"]):
                style_supported(rectangle, geometry[check["target"]["sheet"]])
                style_supported(rectangle, original_geometry[check["target"]["sheet"]])
            original = dict(original_cells)
        mismatches = []
        mismatch_count = 0
        width = rectangle[2] - rectangle[0] + 1
        for index, (coordinate, cell) in enumerate(selected):
            budget.tick()
            if op == "values":
                expected = check["expected"][index // width][index % width]
                actual = actual_value(cell)
                passed = value_matches(actual, expected)
            elif op == "unchanged":
                expected, actual = {}, {}
                for prop in check["properties"]:
                    if prop == "value":
                        expected[prop], actual[prop] = actual_value(original[coordinate]), actual_value(cell)
                    else:
                        expected[prop], actual[prop] = style_value(original[coordinate], prop), style_value(cell, prop)
                passed = expected == actual
            else:
                expected = check["expected"]
                actual = style_value(cell, op, None if op == "number_format" else expected.keys())
                passed = expected == actual
            if not passed:
                mismatch_count += 1
                if len(mismatches) < 20:
                    mismatches.append({"cell": coordinate, "expected": detail(expected), "actual": detail(actual)})
        result.update(status="failed" if mismatch_count else "passed", mismatches=mismatches,
                      mismatch_count=mismatch_count, details_truncated=mismatch_count > len(mismatches))
    except MissingTarget as error:
        result.update(status="failed", reason=str(error))
    except Unsupported as error:
        result.update(status="unsupported", reason=str(error))
    return result


def run(candidate, specification):
    report = {"version": 1, "execution_completed": False, "required_checks_completed": False,
              "conforms": None, "checks": [], "requirements": [],
              "methods": ["bounded_zip_payloads", "openpyxl_saved_cells_and_styles"],
              "not_performed": ["formula_recalculation", "visual_rendering", "viewer_compatibility", "full_xsd_validation"]}
    budget = Budget()
    try:
        if candidate.suffix.lower() != ".xlsx":
            raise SpecError("XLSX candidate required")
        spec = parse_spec(specification)
        with ExitStack() as stack:
            book, geometry, before = opened(stack, candidate, budget, report)
            references = {}
            for check in spec["checks"] if spec else []:
                if check["op"] == "unchanged" and check["original"] not in references:
                    if len(references) >= 4:
                        raise SpecError("Reference input budget exceeded")
                    if fingerprint(check["original"])[:2] == before[:2]:
                        raise SpecError("Original must differ from candidate")
                    references[check["original"]] = opened(stack, Path(check["original"]), budget)
            for check in spec["checks"] if spec else []:
                report["checks"].append(evaluate(check, book, geometry, references, budget))
            if fingerprint(candidate) != before:
                raise RuntimeError("Candidate changed during checking")
            for name, (_, _, original_before) in references.items():
                if fingerprint(name) != original_before:
                    raise RuntimeError("Reference changed during checking")
        budget.tick()
        report["execution_completed"] = True
        report["details_truncated"] = omitted(report["checks"])
        statuses = {check["id"]: check["status"] for check in report["checks"]}
        for requirement in spec["requirements"] if spec else []:
            refs = requirement["checks"]
            state = "unmapped" if not refs else ("failed" if any(statuses[ref] == "failed" for ref in refs)
                    else "unsupported" if any(statuses[ref] == "unsupported" for ref in refs) else "passed")
            report["requirements"].append({**requirement, "status": state})
        required = [item for item in report["requirements"] if item.get("required", True)]
        report["required_checks_completed"] = bool(required) and all(item["status"] in ("passed", "failed") for item in required)
        if "failed" in statuses.values():
            report.update(status="failed", conforms=False)
            return report, 1
        if report["details_truncated"] or "unsupported" in statuses.values() or spec is not None and (not statuses or not report["required_checks_completed"]):
            report["status"] = "incomplete"
            return report, 3
        report.update(status="passed" if spec else "basic_passed", conforms=True if spec else None)
        return report, 0
    except SpecError as error:
        report.update(status="spec_error", error={"type": type(error).__name__, "reason": str(error)})
        return report, 2
    except Unsupported as error:
        report.update(status="incomplete", error={"type": "unsupported", "reason": str(error)})
        return report, 3
    except Exception as error:
        # Exception strings can contain cell values/XML. Keep them in neither
        # stdout nor reports; typed failure is sufficient to route recovery.
        report.update(status="execution_error", error={"type": type(error).__name__[:80]})
        return report, 4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("--checks", type=Path)
    args = parser.parse_args()
    report, code = run(args.candidate, args.checks)
    try:
        encoded = json.dumps(report, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
        if len(encoded) > MAX_REPORT:
            raise BudgetError("Report byte budget exceeded")
        # Exclusive creation rejects every existing path, including aliases.
        # A partial/interrupted JSON file is not a completed report.
        with args.report.open("x", encoding="utf-8") as output:
            try:
                output.write(encoded + "\n")
                output.flush()
            except BaseException:
                # Only this exclusively created handle is touched. An existing
                # report/candidate/alias is never opened for writing.
                try:
                    output.seek(0)
                    output.truncate(0)
                except OSError:
                    pass
                raise
    except Exception as error:
        print(json.dumps({"status": "report_error", "error_type": type(error).__name__[:80]}))
        return 4
    summary = {"status": report["status"], "report": str(args.report)[:4096]}
    if "candidate" in report:
        summary["candidate"] = report["candidate"]
    print(json.dumps(summary, ensure_ascii=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
