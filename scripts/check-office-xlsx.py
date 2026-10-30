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

from openpyxl import load_workbook

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--entry", required=True, type=Path)
args, remaining = parser.parse_known_args()
ENTRY = args.entry.resolve(strict=True)
sys.path.insert(0, str(ROOT / "tests/fixtures/office"))
from xlsx_quality import RAW_ROWS, TOTAL_LABEL, create_summary


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


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *remaining])
