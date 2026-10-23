"""Postconditions for recalculated XLSX files; input must be a checked private ZIP."""
import zipfile
from defusedxml import ElementTree as SafeET
from openpyxl import load_workbook

# Limit dense iteration as well as ZIP expansion; sparse far-away coordinates
# must not cause billions of empty cells to be visited by a result check.
MAX_CHECKED_CELLS = 1_000_000


def _cells(workbook):
    remaining = MAX_CHECKED_CELLS
    for sheet in workbook:
        remaining -= sheet.max_row * sheet.max_column
        if remaining < 0:
            raise ValueError("Workbook result-check cell budget exceeded")
        for row in sheet.iter_rows():
            for cell in row:
                yield sheet.title, cell


def _formulas(filename):
    workbook = load_workbook(filename, data_only=False)
    try:
        formulas = {}
        for sheet, cell in _cells(workbook):
            if cell.data_type == "f":
                value = cell.value
                # openpyxl represents array/data-table formulas as typed
                # objects; compare their fields rather than object identity.
                formulas[(sheet, cell.coordinate)] = value if isinstance(value, str) else (
                    type(value).__name__, vars(value).copy())
        return formulas
    finally:
        workbook.close()


def _check_formula_caches(filename):
    namespace = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    # filename is already a private, fully checked archive. Validate cache
    # presence in XML because a legitimate empty string also decodes as None.
    with zipfile.ZipFile(filename) as archive:
        for name in archive.namelist():
            if not (name.startswith("xl/worksheets/") and name.endswith(".xml")):
                continue
            root = SafeET.fromstring(archive.read(name))
            for cell in root.iter(namespace + "c"):
                if cell.find(namespace + "f") is None:
                    continue
                value = cell.find(namespace + "v")
                if value is None or (value.text is None and cell.get("t") != "str"):
                    raise ValueError(f"Missing recalculated formula cache: {name}!{cell.get('r')}")


def _summary(filename, formula_count):
    workbook = load_workbook(filename, data_only=True)
    try:
        errors = {}
        for sheet, cell in _cells(workbook):
            if cell.data_type == "e":
                details = errors.setdefault(str(cell.value), {"count": 0, "locations": []})
                details["count"] += 1
                if len(details["locations"]) < 20:
                    details["locations"].append(f"{sheet}!{cell.coordinate}")
        total = sum(details["count"] for details in errors.values())
        return {"status": "errors_found" if total else "success", "total_errors": total,
                "error_summary": errors, "total_formulas": formula_count}
    finally:
        workbook.close()

