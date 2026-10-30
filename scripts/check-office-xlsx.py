"""XLSX quality qualification; run using the selected Skill's private Python.

Usage: <run entry> python scripts/check-office-xlsx.py --entry <run entry>
All inputs are synthetic. Expected values are independent of authoring row indices.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from openpyxl import load_workbook

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--entry", required=True, type=Path)
args, remaining = parser.parse_known_args()
ENTRY = args.entry.resolve(strict=True)
sys.path.insert(0, str(ROOT / "tests/fixtures/office"))
from xlsx_quality import RAW_ROWS, TOTAL_LABEL, create_summary

VERIFY = ENTRY.parent.parent / "scripts/verify.py"


def quality_spec():
    checks = [
        {"id": "sheets", "op": "sheets", "expected": ["Input", "Data", "Regions", "Reference"]},
        {"id": "orders", "op": "values", "target": {"sheet": "Data", "range": "A2:A5"},
         "expected": [[{"type": "string", "value": value}] for value in ("o-1", "o-2", "o-3", "o-4")]},
        {"id": "count", "op": "count", "target": {"sheet": "Data", "range": "A2:A5"}, "expected": 4},
        {"id": "amounts-and-shares", "op": "values", "target": {"sheet": "Data", "range": "C2:D6"},
         "expected": [[{"type": "number", "value": amount, "tolerance": 0}, {"type": "number", "value": share, "tolerance": 1e-12}]
                      for amount, share in ((100, 2/13), (200, 4/13), (150, 3/13), (200, 4/13), (650, 1))]},
        {"id": "regions", "op": "values", "target": {"sheet": "Regions", "range": "A2:C4"},
         "expected": [[{"type": "string", "value": region}, {"type": "number", "value": amount, "tolerance": 0},
                       {"type": "number", "value": share, "tolerance": 1e-12}]
                      for region, amount, share in (("North", 300, 6/13), ("South", 350, 7/13), ("Total", 650, 1))]},
    ]
    for name, region, cell, total_range, percent, amount_offset in (
        ("Data", "A1:D6", "A6", "A2:A6", "D2:D6", 2),
        ("Regions", "A1:C4", "A4", "A2:A4", "C2:C4", 1),
    ):
        checks.extend([
            {"id": name + "-label", "op": "label", "target": {"sheet": name, "range": total_range},
             "expected": {"value": "Total", "cell": cell}},
            {"id": name + "-font", "op": "font", "target": {"sheet": name, "range": region}, "expected": {"name": "Arial", "size": 11}},
            {"id": name + "-percent", "op": "number_format", "target": {"sheet": name, "range": percent}, "expected": "0.0%"},
            {"id": name + "-amount", "op": "values", "target": {"sheet": name, "label": {"range": total_range, "value": "Total"}, "offset": [0, amount_offset]},
             "expected": [[{"type": "number", "value": 650, "tolerance": 0}]]},
            {"id": name + "-fill", "op": "fill", "target": {"sheet": name, "range": cell}, "expected": {"pattern": "solid", "color": "FFDEEAF6"}},
        ])
    return {"version": 1, "checks": checks, "requirements": [
        {"id": check["id"], "source": "Synthetic task: independent expected data and requested stored formatting", "checks": [check["id"]]}
        for check in checks
    ]}


def one_check(check):
    return {"version": 1, "checks": [check], "requirements": [{"id": "task", "source": "Fixed test requirement", "checks": [check["id"]]}]}


def invoke(script, *arguments):
    command = ["/bin/sh", str(ENTRY), "python"] if ENTRY.suffix == ".sh" else [str(ENTRY), "python"]
    return subprocess.run(command + [str(script), *map(str, arguments)],
                          capture_output=True, text=True, timeout=30)


class QualityBaseline(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="office-xlsx-")
        self.work = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_independent_numeric_and_style_oracle_distinguishes_good_and_bad(self):
        # Fixed expected orders and regions come from the task input, not the
        # authoring loop, returned total row, or production selector code.
        expected_orders = {"o-1": 100, "o-2": 200, "o-3": 150, "o-4": 200}
        expected_regions = {"North": 300, "South": 350}
        self.assertEqual(len(RAW_ROWS), 7)
        for faulty in (False, True):
            with self.subTest(faulty=faulty):
                candidate = self.work / ("bad.xlsx" if faulty else "good.xlsx")
                create_summary(candidate, faulty_totals=faulty)
                book = load_workbook(candidate)
                try:
                    self.assertEqual(book.sheetnames, ["Input", "Data", "Regions", "Reference"])
                    actual_orders = {row[0]: row[2] for row in book["Data"].iter_rows(min_row=2, values_only=True)
                                     if row[0] != TOTAL_LABEL}
                    actual_regions = {row[0]: row[1] for row in book["Regions"].iter_rows(min_row=2, values_only=True)
                                      if row[0] != TOTAL_LABEL}
                    self.assertEqual(actual_orders, expected_orders)
                    self.assertEqual(actual_regions, expected_regions)
                    for name, label_column, amount_column, share_column, expected_row in (
                        ("Data", 1, 3, 4, 6), ("Regions", 1, 2, 3, 4)
                    ):
                        sheet = book[name]
                        labels = [cell for row in sheet.iter_rows() for cell in row
                                  if cell.value == TOTAL_LABEL]
                        self.assertEqual([(cell.row, cell.column) for cell in labels], [(expected_row, label_column)])
                        self.assertEqual(sheet.cell(expected_row, amount_column).value, sum(expected_orders.values()))
                        self.assertEqual(sheet.cell(expected_row, share_column).value, 1)
                        self.assertEqual(sheet["A1"].font.name, "Arial")  # The old A1 check misses the defect.
                        self.assertEqual(sheet.cell(expected_row, 1).font.name == "Arial", not faulty)
                        self.assertEqual(sheet.cell(expected_row, share_column).number_format == "0.0%", not faulty)
                finally:
                    book.close()


    def test_structured_reader_cannot_substitute_for_style_verification(self):
        parsed = []
        for faulty in (False, True):
            source = self.work / ("bad.xlsx" if faulty else "good.xlsx")
            output = source.with_suffix(".json")
            create_summary(source, faulty_totals=faulty)
            before = hashlib.sha256(source.read_bytes()).digest()
            result = invoke(ENTRY.parent / "read.py", source, output)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
            parsed.append(json.loads(output.read_text(encoding="utf-8")))
        self.assertEqual(parsed[0], parsed[1])

    def test_zero_one_and_multiple_groups_have_explicit_total_and_zero_rules(self):
        for rows, counts, regions, amount in (
            ((), 0, 0, 0),
            ((("one", "East", 0),), 1, 1, 0),
            ((("one", "East", 5),), 1, 1, 5),
            (RAW_ROWS, 4, 2, 650),
        ):
            with self.subTest(rows=rows):
                candidate = self.work / "sample.xlsx"
                create_summary(candidate, rows)
                book = load_workbook(candidate)
                try:
                    for name, expected_rows, amount_column, share_column in (
                        ("Data", counts + 2, 3, 4), ("Regions", regions + 2, 2, 3)
                    ):
                        sheet = book[name]
                        self.assertEqual(sheet.max_row, expected_rows)
                        self.assertEqual(sheet.cell(expected_rows, 1).value, TOTAL_LABEL)
                        self.assertEqual(sheet.cell(expected_rows, amount_column).value, amount)
                        self.assertEqual(sheet.cell(expected_rows, share_column).value, 0 if amount == 0 else 1)
                        self.assertEqual(sheet.cell(expected_rows, share_column).number_format, "0.0%")
                        self.assertEqual(sheet.cell(expected_rows, 1).font.name, "Arial")
                    self.assertEqual(book["Reference"]["H20"].value, "Outside the edited range")
                    self.assertEqual(book["Reference"]["B2"].value, "=1+2")
                finally:
                    book.close()


class Verification(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="office-verify-")
        self.work = Path(self.temporary.name)
        self.candidate = self.work / "candidate.xlsx"
        create_summary(self.candidate)
        self.sequence = 0

    def tearDown(self):
        self.temporary.cleanup()

    def verify(self, spec=None, candidate=None):
        self.sequence += 1
        report_path = self.work / f"report-{self.sequence}.json"
        arguments = []
        if spec is not None:
            specification = self.work / f"checks-{self.sequence}.json"
            specification.write_text(json.dumps(spec), encoding="utf-8")
            arguments = ["--checks", specification]
        result = invoke(VERIFY, candidate or self.candidate, report_path, *arguments)
        self.assertTrue(report_path.is_file(), result.stdout + result.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        summary = json.loads(result.stdout)
        self.assertEqual(summary["status"], report["status"])
        return result, report

    def change(self, edit):
        book = load_workbook(self.candidate)
        try:
            edit(book)
            book.save(self.candidate)
        finally:
            book.close()

    def test_good_summary_passes_and_report_binds_exact_bytes(self):
        before = self.candidate.read_bytes()
        result, report = self.verify(quality_spec())
        self.assertEqual(result.returncode, 0, report)
        self.assertTrue(report["execution_completed"] and report["required_checks_completed"] and report["conforms"])
        self.assertEqual(report["candidate"], {"bytes": len(before), "sha256": hashlib.sha256(before).hexdigest()})
        self.assertEqual(before, self.candidate.read_bytes())
        self.assertNotIn("o-1", result.stdout)
        self.assertNotIn("sheets", result.stdout)
        self.assertIn("formula_recalculation", report["not_performed"])

    def test_bad_total_styles_are_detected_at_both_independently_found_rows(self):
        create_summary(self.candidate, faulty_totals=True)
        result, report = self.verify(quality_spec())
        self.assertEqual(result.returncode, 1, report)
        checks = {check["id"]: check for check in report["checks"]}
        self.assertEqual(checks["Data-font"]["status"], "failed")
        self.assertEqual(checks["Regions-font"]["status"], "failed")
        self.assertIn("A6", [item["cell"] for item in checks["Data-font"]["mismatches"]])
        self.assertIn("A4", [item["cell"] for item in checks["Regions-font"]["mismatches"]])
        self.assertEqual(checks["Data-amount"]["status"], "passed")

    def test_every_necessary_mutation_fails(self):
        for sheet, coordinate, value in (("Data", "C6", 649), ("Data", "A6", "Wrong total"),
                                         ("Regions", "A2", "Wrong region"), ("Data", "A3", "duplicate")):
            with self.subTest(sheet=sheet, coordinate=coordinate):
                create_summary(self.candidate)
                self.change(lambda book: setattr(book[sheet][coordinate], "value", value))
                spec = quality_spec()
                result, report = self.verify(spec)
                self.assertEqual(result.returncode, 1, report)
                self.assertFalse(report["conforms"])

    def test_missing_ambiguous_and_empty_selectors_fail_without_vacuous_success(self):
        for target, op, expected in (
            ({"sheet": "Missing", "range": "A1"}, "font", {"name": "Arial"}),
            ({"sheet": "Data", "range": "H100:H101"}, "font", {"name": "Arial"}),
            ({"sheet": "Data", "label": {"range": "A2:A5", "value": "Total"}}, "font", {"name": "Arial"}),
            ({"sheet": "Data", "range": "H100"}, "values", [[{"type": "number", "value": 0, "tolerance": 0}]]),
        ):
            with self.subTest(target=target):
                result, report = self.verify(one_check({"id": "target", "op": op, "target": target, "expected": expected}))
                self.assertEqual(result.returncode, 1, report)
        self.change(lambda book: setattr(book["Data"]["A3"], "value", "Total"))
        result, report = self.verify(one_check({"id": "label", "op": "font", "target": {"sheet": "Data", "label": {"range": "A2:A6", "value": "Total"}}, "expected": {"name": "Arial"}}))
        self.assertEqual(result.returncode, 1, report)
        self.assertEqual(report["checks"][0]["reason"], "label_ambiguous")

    def test_explicit_empty_count_passes_while_empty_style_scope_does_not(self):
        check = {"id": "empty", "op": "count", "target": {"sheet": "Data", "range": "H100:H101"}, "expected": 0}
        result, report = self.verify(one_check(check))
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report["checks"][0]["actual"], 0)

    def test_formula_text_boolean_blank_and_numeric_zero_are_distinct(self):
        checks = (("Reference", "B2", {"type": "formula", "value": "=1+2"}, 0),
                  ("Reference", "B2", {"type": "number", "value": 3, "tolerance": 0}, 1),
                  ("Reference", "C2", {"type": "blank"}, 0),
                  ("Reference", "C2", {"type": "number", "value": 0, "tolerance": 0}, 1))
        for sheet, coordinate, expected, code in checks:
            with self.subTest(expected=expected):
                result, report = self.verify(one_check({"id": "typed", "op": "values", "target": {"sheet": sheet, "range": coordinate}, "expected": [[expected]]}))
                self.assertEqual(result.returncode, code, report)
        self.change(lambda book: setattr(book["Data"]["C2"], "value", True))
        result, report = self.verify(one_check({"id": "boolean", "op": "values", "target": {"sheet": "Data", "range": "C2"}, "expected": [[{"type": "number", "value": 1, "tolerance": 0}]]}))
        self.assertEqual(result.returncode, 1, report)

    def test_original_preservation_covers_only_declared_semantics_and_rejects_self_comparison(self):
        original = self.work / "original.xlsx"
        original.write_bytes(self.candidate.read_bytes())
        check = {"id": "preserve", "op": "unchanged", "target": {"sheet": "Reference", "range": "A1:H20"}, "original": str(original), "properties": ["value", "number_format"]}
        self.change(lambda book: setattr(book["Data"]["C2"], "value", 99))
        before = original.read_bytes()
        result, report = self.verify(one_check(check))
        self.assertEqual(result.returncode, 0, report)
        self.change(lambda book: setattr(book["Reference"]["H20"], "value", "changed"))
        result, report = self.verify(one_check(check))
        self.assertEqual(result.returncode, 1, report)
        self.assertEqual(original.read_bytes(), before)
        check["original"] = str(self.candidate)
        result, report = self.verify(one_check(check))
        self.assertEqual(result.returncode, 2, report)

    def test_preserved_font_includes_underline_and_other_stored_font_properties(self):
        from copy import copy
        original = self.work / "original.xlsx"
        original.write_bytes(self.candidate.read_bytes())
        check = {"id": "font", "op": "unchanged", "target": {"sheet": "Data", "range": "A2"}, "original": str(original), "properties": ["font"]}
        result, report = self.verify(one_check(check))
        self.assertEqual(result.returncode, 0, report)
        def underline(book):
            font = copy(book["Data"]["A2"].font)
            font.u = "single"
            book["Data"]["A2"].font = font
        self.change(underline)
        result, report = self.verify(one_check(check))
        self.assertEqual(result.returncode, 1, report)

    def test_invalid_specs_and_unknown_operations_do_not_edit_documents(self):
        before = self.candidate.read_bytes()
        valid = {"id": "value", "op": "values", "target": {"sheet": "Data", "range": "A1"}, "expected": [[{"type": "string", "value": "Order"}]]}
        cases = [one_check({**valid, "op": "execute"}), one_check({**valid, "target": {"sheet": "Data", "range": "A0"}}),
                 one_check({**valid, "target": {"sheet": "Data", "range": "XFE1"}}),
                 one_check({**valid, "target": {"sheet": "Data", "range": "A1:XFD1048576"}}),
                 one_check({**valid, "expected": [[{"type": "number", "value": 0, "tolerance": -1}]]}),
                 one_check({**valid, "expected": [[{"type": [], "value": 0}]]})]
        for spec in cases:
            with self.subTest(spec=spec):
                result, report = self.verify(spec)
                self.assertEqual(result.returncode, 2, report)
                self.assertFalse(report["execution_completed"])
        self.assertEqual(self.candidate.read_bytes(), before)

    def test_missing_requirements_empty_checks_and_unsupported_never_pass(self):
        for spec in (
            {"version": 1, "checks": [], "requirements": []},
            {"version": 1, "checks": [], "requirements": [{"id": "missing", "source": "Necessary visual requirement", "checks": []}]},
            one_check({"id": "visual", "op": "unsupported", "reason": "No rendering in this runtime"}),
        ):
            result, report = self.verify(spec)
            self.assertEqual(result.returncode, 3, report)
            self.assertIsNone(report["conforms"])
        result, report = self.verify()
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report["status"], "basic_passed")
        self.assertFalse(report["required_checks_completed"])
        self.assertIsNone(report["conforms"])

    def test_theme_and_conditional_style_scopes_are_explicitly_unsupported(self):
        from openpyxl.formatting.rule import CellIsRule
        from openpyxl.styles import Color, Font
        def theme(book):
            book["Data"]["A2"].font = Font(name="Arial", color=Color(theme=1))
        self.change(theme)
        result, report = self.verify(one_check({"id": "theme", "op": "font", "target": {"sheet": "Data", "range": "A2"}, "expected": {"color": "FF000000"}}))
        self.assertEqual(result.returncode, 3, report)
        self.change(lambda book: book["Data"].conditional_formatting.add("C2:C6", CellIsRule(operator="greaterThan", formula=["0"], font=Font(bold=True))))
        result, report = self.verify(one_check({"id": "conditional", "op": "font", "target": {"sheet": "Data", "range": "C2:C6"}, "expected": {"bold": False}}))
        self.assertEqual(result.returncode, 3, report)

    def test_exclusive_report_creation_never_overwrites_candidates_originals_or_aliases(self):
        import os
        original = self.candidate.read_bytes()
        hardlink = self.work / "hardlink.json"
        os.link(self.candidate, hardlink)
        for report_path in (self.candidate, hardlink):
            result = invoke(VERIFY, self.candidate, report_path)
            self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "report_error")
        self.assertEqual(self.candidate.read_bytes(), original)

    def test_corrupt_hostile_xml_sparse_extent_and_missing_input_are_execution_errors(self):
        for kind in ("corrupt", "traversal", "entity", "sparse", "missing"):
            with self.subTest(kind=kind):
                path = self.work / (kind + ".xlsx")
                if kind == "corrupt":
                    path.write_bytes(b"not a zip")
                elif kind == "traversal":
                    with zipfile.ZipFile(path, "w") as archive:
                        archive.writestr("../escape", "bad")
                elif kind in ("entity", "sparse"):
                    with zipfile.ZipFile(self.candidate) as source, zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                        for entry in source.infolist():
                            content = source.read(entry)
                            if entry.filename == "xl/worksheets/sheet1.xml":
                                content = (b'<!DOCTYPE worksheet [<!ENTITY x "PRIVATE_DOCUMENT_MARKER">]>' + content) if kind == "entity" else content.replace(b'A1:C8', b'A1:XFD1048576')
                            archive.writestr(entry, content)
                result, report = self.verify(candidate=path)
                self.assertEqual(result.returncode, 4, report)
                self.assertFalse(report["execution_completed"])
                self.assertIsNone(report["conforms"])
                self.assertNotIn("PRIVATE_DOCUMENT_MARKER", result.stdout + result.stderr)

    def test_input_change_cannot_publish_success(self):
        # Exercise the same production functions under controlled mutation and
        # write failure; do not race filesystem scheduling probabilistically.
        import importlib.util
        definition = importlib.util.spec_from_file_location("xlsx_verify", VERIFY)
        module = importlib.util.module_from_spec(definition)
        definition.loader.exec_module(module)
        specification = self.work / "checks.json"
        specification.write_text(json.dumps(quality_spec()), encoding="utf-8")
        actual = module.evaluate
        changed = False
        def mutate(*arguments):
            nonlocal changed
            result = actual(*arguments)
            if not changed:
                changed = True
                self.candidate.write_bytes(self.candidate.read_bytes() + b"changed")
            return result
        with patch.object(module, "evaluate", side_effect=mutate):
            report, code = module.run(self.candidate, specification)
        self.assertEqual(code, 4, report)
        self.assertFalse(report["execution_completed"])
        self.assertIsNone(report["conforms"])

    def test_reference_change_and_runtime_budget_cannot_be_assertion_failures(self):
        import importlib.util
        definition = importlib.util.spec_from_file_location("xlsx_verify", VERIFY)
        module = importlib.util.module_from_spec(definition)
        definition.loader.exec_module(module)
        original = self.work / "original.xlsx"
        original.write_bytes(self.candidate.read_bytes())
        specification = self.work / "checks.json"
        specification.write_text(json.dumps(one_check({"id": "keep", "op": "unchanged", "target": {"sheet": "Reference", "range": "A1:H20"}, "properties": ["value"], "original": str(original)})), encoding="utf-8")
        actual = module.evaluate
        def mutate(*arguments):
            result = actual(*arguments)
            original.write_bytes(original.read_bytes() + b"changed")
            return result
        with patch.object(module, "evaluate", side_effect=mutate):
            report, code = module.run(self.candidate, specification)
        self.assertEqual(code, 4, report)
        self.assertFalse(report["execution_completed"])
        with patch.object(module.Budget, "tick", side_effect=module.BudgetError("test time budget")):
            report, code = module.run(self.candidate, None)
        self.assertEqual(code, 4, report)
        self.assertEqual(report["error"]["type"], "BudgetError")

    def test_partial_report_write_and_report_capacity_are_not_success(self):
        import contextlib
        import importlib.util
        import io
        definition = importlib.util.spec_from_file_location("xlsx_verify", VERIFY)
        module = importlib.util.module_from_spec(definition)
        definition.loader.exec_module(module)
        destination = self.work / "partial.json"
        real_open = Path.open
        class BrokenWriter:
            def __enter__(self):
                self.file = real_open(destination, "x", encoding="utf-8")
                return self
            def __exit__(self, *unused):
                self.file.close()
            def write(self, content):
                self.file.write(content[:20])
                raise OSError("simulated disk write failure")
            def seek(self, offset):
                return self.file.seek(offset)
            def truncate(self, size):
                return self.file.truncate(size)
        def controlled_open(path, *arguments, **options):
            return BrokenWriter() if path == destination else real_open(path, *arguments, **options)
        output = io.StringIO()
        with patch.object(sys, "argv", [str(VERIFY), str(self.candidate), str(destination)]), patch.object(Path, "open", controlled_open), contextlib.redirect_stdout(output):
            code = module.main()
        self.assertEqual(code, 4)
        self.assertEqual(json.loads(output.getvalue())["status"], "report_error")
        with self.assertRaises(json.JSONDecodeError):
            json.loads(destination.read_text())
        output = io.StringIO()
        too_small = self.work / "too-small.json"
        with patch.object(module, "MAX_REPORT", 10), patch.object(sys, "argv", [str(VERIFY), str(self.candidate), str(too_small)]), contextlib.redirect_stdout(output):
            code = module.main()
        self.assertEqual(code, 4)
        self.assertFalse(too_small.exists())

    def test_malformed_duplicate_oversized_specs_and_wrong_format_are_spec_errors(self):
        for index, content in enumerate((b"{broken", b'{"version":1,"version":1,"checks":[],"requirements":[]}', b" " * (256 * 1024 + 1))):
            specification = self.work / f"invalid-{index}.json"
            report_path = self.work / f"invalid-report-{index}.json"
            specification.write_bytes(content)
            result = invoke(VERIFY, self.candidate, report_path, "--checks", specification)
            report = json.loads(report_path.read_text())
            self.assertEqual(result.returncode, 2, report)
            self.assertEqual(report["status"], "spec_error")
        wrong = self.work / "document.docx"
        wrong.write_bytes(self.candidate.read_bytes())
        result, report = self.verify(candidate=wrong)
        self.assertEqual(result.returncode, 2, report)

    def test_truncated_details_are_explicit_and_never_pass(self):
        self.change(lambda book: [setattr(book["Data"].cell(row, 1), "value", "long expected value " * 20) for row in range(10, 40)])
        expected = [[{"type": "string", "value": "long expected value " * 20}] for _ in range(30)]
        result, report = self.verify(one_check({"id": "large", "op": "values", "target": {"sheet": "Data", "range": "A10:A39"}, "expected": expected}))
        self.assertEqual(result.returncode, 0, report)
        self.assertFalse(report["details_truncated"])
        self.change(lambda book: [setattr(book["Data"].cell(row, 1), "value", "wrong") for row in range(10, 40)])
        result, report = self.verify(one_check({"id": "large", "op": "values", "target": {"sheet": "Data", "range": "A10:A39"}, "expected": expected}))
        self.assertEqual(result.returncode, 1, report)
        self.assertTrue(report["details_truncated"])
        self.assertFalse(report["conforms"])

    def test_zero_input_and_zero_amount_are_checked_with_declared_rules(self):
        for rows, coordinate in (((), "A2"), ((("only", "East", 0),), "A3")):
            create_summary(self.candidate, rows)
            checks = [
                {"id": "total", "op": "label", "target": {"sheet": "Data", "range": "A2:A3"}, "expected": {"value": "Total", "cell": coordinate}},
                {"id": "zero", "op": "values", "target": {"sheet": "Data", "label": {"range": "A2:A3", "value": "Total"}, "offset": [0, 2], "size": [1, 2]},
                 "expected": [[{"type": "number", "value": 0, "tolerance": 0}, {"type": "number", "value": 0, "tolerance": 0}]]},
            ]
            spec = {"version": 1, "checks": checks, "requirements": [{"id": "zero-rule", "source": "Zero total explicitly means zero share", "checks": ["total", "zero"]}]}
            result, report = self.verify(spec)
            self.assertEqual(result.returncode, 0, report)



if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *remaining])
