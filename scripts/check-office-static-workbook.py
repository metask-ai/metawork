"""Qualify saved-value-only XLSX layout against the real component engine.

--source is an explicit source overlay; it never edits an accepted component
or qualifies its installed payload. Retained small fixtures support visual QA.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import zipfile

from lxml import etree
from openpyxl import Workbook
from openpyxl.chart import BarChart, Reference
from openpyxl.formatting.rule import FormulaRule
from openpyxl.workbook.defined_name import DefinedName
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.worksheet.pagebreak import Break
from PIL import Image
from pypdf import PdfReader

parser = argparse.ArgumentParser()
parser.add_argument("component", type=Path)
parser.add_argument("--source", action="store_true")
options, remaining = parser.parse_known_args()
sys.argv = [sys.argv[0], *remaining]
COMPONENT = options.component.resolve(strict=True)
REPO = Path(__file__).resolve().parents[1]
TOOLS = REPO / "src/product/skill/office_runtime" if options.source else COMPONENT / "tools"
sys.path.insert(0, str(TOOLS))
import static_workbook as static

spec = importlib.util.spec_from_file_location("layout_controller", TOOLS / "office.py")
office = importlib.util.module_from_spec(spec)
spec.loader.exec_module(office)
if options.source:
    office.ROOT = COMPONENT
    office.PROGRAM = COMPONENT / "engine/program"
    sys.path.insert(0, str(office.PROGRAM))
S = "{" + static.S + "}"
C = "{" + static.C + "}"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rewrite(source, destination, transform):
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED) as output:
        for item in original.infolist():
            output.writestr(item, transform(item.filename, original.read(item)))


class StaticWorkbookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = REPO / ".zig-cache/office-static-workbook-qualification"
        parent.mkdir(exist_ok=True)
        cls.root = Path(tempfile.mkdtemp(prefix="source-" if options.source else "installed-", dir=parent))
        cls.manifest = digest(COMPONENT / "office-runtime.json")
        cls.rendered = []

    @classmethod
    def tearDownClass(cls):
        if digest(COMPONENT / "office-runtime.json") != cls.manifest:
            raise AssertionError("Qualification altered component manifest")
        evidence = {"scope": "source overlay" if options.source else "installed resources",
                    "componentManifestSha256": cls.manifest, "rendered": cls.rendered}
        (cls.root / "evidence.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"directory": str(cls.root), "scope": evidence["scope"]}))

    def source(self, label):
        original = self.root / (label + "-original.xlsx")
        book = Workbook()
        sheet = book.active
        sheet.title = "数据 中文"
        for row in [["Saved layout 中文", "Result"], ["constant", "=1+2"],
                    ["volatile", "=NOW()"], ["random", "=RAND()"],
                    ["missing", "=SUM(1,2)"], ["string", '="=1+2"'],
                    ["cached boolean", "=TRUE()"], ["cached error", "=1/0"]]:
            sheet.append(row)
        sheet.column_dimensions["A"].width = 28
        sheet.column_dimensions["B"].width = 24
        sheet.print_area = "A1:H8"
        sheet.print_title_rows = "1:1"
        sheet.row_breaks.append(Break(id=4))
        sheet.sheet_properties.pageSetUpPr.fitToPage = False
        hidden = book.create_sheet("Hidden")
        hidden["A1"] = "HIDDEN-SHEET-MUST-NOT-PRINT"
        hidden.sheet_state = "hidden"
        book.save(original)
        source = self.root / (label + ".xlsx")
        def caches(name, data):
            if name == "xl/worksheets/sheet1.xml":
                root = etree.fromstring(data)
                values = {"B2": ("n", "999"), "B3": ("n", "111"), "B4": ("n", "222"),
                          "B6": ("str", "=1+2"), "B7": ("b", "1"), "B8": ("e", "#DIV/0!")}
                for cell in root.iter(S + "c"):
                    if cell.get("r") in values:
                        kind, value = values[cell.get("r")]
                        cell.set("t", kind)
                        cell.find(S + "v").text = value
                return etree.tostring(root)
            return data
        rewrite(original, source, caches)
        return source

    def test_freezes_cached_missing_volatile_string_boolean_and_error_without_touching_source(self):
        source = self.source("values")
        before = digest(source)
        frozen = self.root / "values-static.xlsx"
        with office.checked_input(source) as (checked, _):
            report = static.freeze(checked, frozen)
        self.assertEqual(report["formula_cells"], 7)
        self.assertEqual(report["missing_formula_caches"], 1)
        self.assertEqual(report["removed_defined_names"], 0)
        with zipfile.ZipFile(frozen) as archive:
            root = etree.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            self.assertEqual(list(root.iter(S + "f")), [])
            cells = {node.get("r"): node for node in root.iter(S + "c")}
            for name, value in [("B2", "999"), ("B3", "111"), ("B4", "222")]:
                self.assertEqual(cells[name].find(S + "v").text, value)
            self.assertIsNone(cells["B5"].find(S + "v"))
            self.assertEqual(cells["B6"].get("t"), "inlineStr")
            self.assertEqual(cells["B6"].find(".//" + S + "t").text, "=1+2")
            for name, value in [("B7", "TRUE"), ("B8", "#DIV/0!")]:
                self.assertEqual(cells[name].find(".//" + S + "t").text, value)
        self.assertEqual(digest(source), before)

    def test_reference_grammar_rejects_expressions_external_workbooks_and_overflow(self):
        sheets = {"Data", "Data, Q1", "A'B", "Data+NOW()"}
        for value in ["Data!$A$1:$C$8", "'Data, Q1'!$A:$C", "'A''B'!$1:$2", "Data!$A$1,Data!$B$2", "'Data+NOW()'!A1"]:
            self.assertTrue(static.literal_ranges(value, sheets), value)
        for value in ["Data!$A$10001", "Data!$IW$1", "[Book]Data!A1", "Data!A1+WEBSERVICE(\"x\")",
                      "SUM(Data!A1)", "Data!A1,", "Data!A1,,Data!B2", "Other!A1", "Data!A1#", "Data!$A:$1", "Data+NOW()!A1"]:
            self.assertFalse(static.literal_ranges(value, sheets), value)

    def test_formula_rules_are_omitted_and_literal_print_ranges_preserved(self):
        book = Workbook()
        sheet = book.active
        sheet["A1"] = "a"
        sheet.conditional_formatting.add("A1", FormulaRule(formula=['WEBSERVICE("https://example.invalid")']))
        validation = DataValidation(type="custom", formula1='WEBSERVICE("https://example.invalid")')
        sheet.add_data_validation(validation)
        validation.add(sheet["A1"])
        sheet.print_area = "A1:B4"
        original = self.root / "rules.xlsx"
        book.save(original)
        frozen = self.root / "rules-static.xlsx"
        with office.checked_input(original) as (checked, _):
            report = static.freeze(checked, frozen)
        self.assertEqual(report["omissions"], ["conditional_formatting", "data_validation"])
        with zipfile.ZipFile(frozen) as archive:
            xml = archive.read("xl/worksheets/sheet1.xml")
            self.assertNotIn(b"WEBSERVICE", xml)
            self.assertNotIn(b"conditionalFormatting", xml)
            self.assertNotIn(b"dataValidations", xml)
            self.assertIn(b"Print_Area", archive.read("xl/workbook.xml"))

    def test_rejects_active_parts_extensions_dtd_and_chart_expressions_before_load(self):
        for index, (part, data) in enumerate([
            ("xl/connections.xml", b"<connections/>"),
            ("xl/pivotTables/pivotTable1.xml", b"<pivotTable/>"),
            ("xl/charts/chart1.xml", f'<c:chartSpace xmlns:c="{static.C}"><c:f>SUM(Sheet!A1)</c:f></c:chartSpace>'.encode()),
            ("xl/worksheets/sheet2.xml", f'<worksheet xmlns="{static.S}"><extLst/></worksheet>'.encode()),
            ("xl/worksheets/sheet2.xml", b'<!DOCTYPE doc [<!ENTITY x "bad">]><doc>&x;</doc>'),
            ("xl/renamed-active.bin", b"not a supported passive resource"),
            ("xl/_rels/renamed.xml.rels", b'<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing" Target="../renamed.xml"/></Relationships>'),
        ]):
            book = Workbook()
            source = self.root / f"bad-{index}.xlsx"
            book.save(source)
            with zipfile.ZipFile(source, "a") as archive:
                archive.writestr(part, data)
            scratch = self.root / f"rejected-{index}"
            scratch.mkdir()
            with office.checked_input(source) as (checked, _), patch.object(office.Engine, "load", side_effect=AssertionError("Unsafe document loaded")):
                with self.assertRaises((ValueError, etree.XMLSyntaxError)):
                    office.render(type("UnusedEngine", (), {"directory": scratch})(), checked, scratch, 640)

    def test_actual_engine_keeps_saved_values_missing_blank_print_pages_and_chinese(self):
        source = self.source("engine")
        before = digest(source)
        scratch = self.root / "engine"
        scratch.mkdir()
        pages = scratch / "pages"
        pages.mkdir()
        with office.checked_input(source) as (checked, _), office.Engine(scratch) as engine:
            result = office.render(engine, checked, pages, 640, max_pages=100, byte_budget=64*1024*1024)
            self.assertTrue(result["saved_values_only"])
            self.assertEqual(result["page_count"], 2)
            frozen = engine.documents[0]
            sheet = frozen.Sheets.getByIndex(0)
            for name, value in [("B2", 999), ("B3", 111), ("B4", 222), ("B5", 0)]:
                cell = sheet.getCellRangeByName(name)
                self.assertEqual(cell.getValue(), value, (name, cell.getString(), cell.getType(), cell.getError()))
                self.assertNotEqual(cell.getType().value, "FORMULA")
            self.assertEqual(sheet.getCellRangeByName("B6").getString(), "=1+2")
            for name, value in [("B7", "TRUE"), ("B8", "#DIV/0!")]:
                self.assertEqual(sheet.getCellRangeByName(name).getString(), value)
                self.assertNotEqual(sheet.getCellRangeByName(name).getType().value, "FORMULA")
            text = "\n".join(page.extract_text() for page in PdfReader(scratch / "preview.pdf").pages)
            self.assertIn("999", text)
            self.assertIn("111", text)
            self.assertIn("222", text)
            self.assertIn("中文", text)
            self.assertNotIn("HIDDEN-SHEET-MUST-NOT-PRINT", text)
        self.assertEqual(digest(source), before)
        self.rendered.append({"name": "saved-values-and-printing", "pages": str(pages.relative_to(self.root)), **result})

    def test_actual_chart_uses_static_cell_ranges_and_preserves_graphics(self):
        book = Workbook()
        sheet = book.active
        sheet.append(["Quarter", "Sales"])
        sheet.append(["Q1", 12])
        sheet.append(["Q2", 24])
        chart = BarChart()
        chart.title = "Sales 中文"
        chart.add_data(Reference(sheet, min_col=2, min_row=1, max_row=3), titles_from_data=True)
        chart.set_categories(Reference(sheet, min_col=1, min_row=2, max_row=3))
        chart.series[0].graphicalProperties.solidFill = "3366CC"
        sheet.add_chart(chart, "D1")
        sheet.print_area = "A1:M17"
        sheet.sheet_properties.pageSetUpPr.fitToPage = True
        sheet.page_setup.fitToWidth = 1
        sheet.page_setup.fitToHeight = 1
        source = self.root / "chart.xlsx"
        book.save(source)
        scratch = self.root / "chart"
        scratch.mkdir()
        pages = scratch / "pages"
        pages.mkdir()
        with office.checked_input(source) as (checked, _), office.Engine(scratch) as engine:
            result = office.render(engine, checked, pages, 800)
        self.assertEqual(result["page_count"], 1)
        with Image.open(pages / "page-0001.png") as image:
            colored = sum(1 for red, green, blue in image.convert("RGB").get_flattened_data()
                          if blue > 100 and red < 100 and green < 180)
        self.assertGreater(colored, 1000, "actual chart bars must be present")
        self.rendered.append({"name": "chart", "bluePixels": colored, "pages": str(pages.relative_to(self.root)), **result})

    def test_actual_pdf_export_does_not_execute_web_formulas_names_or_hyperlinks(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"computed")
            def log_message(self, *_):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/must-not-execute"
            book = Workbook()
            sheet = book.active
            sheet["A1"] = f'=WEBSERVICE("{url}")'
            sheet["A2"] = "=network_name"
            sheet["A3"] = "Click link"
            sheet["A3"].hyperlink = url
            book.defined_names.add(DefinedName("network_name", attr_text=f'WEBSERVICE("{url}")'))
            original = self.root / "network-original.xlsx"
            book.save(original)
            source = self.root / "network.xlsx"
            def cache(name, data):
                if name == "xl/worksheets/sheet1.xml":
                    root = etree.fromstring(data)
                    for cell in root.iter(S + "c"):
                        if cell.get("r") in ("A1", "A2"):
                            cell.set("t", "str")
                            cell.find(S + "v").text = "saved-only"
                    return etree.tostring(root)
                return data
            rewrite(original, source, cache)
            before = digest(source)
            destination = self.root / "network.pdf"
            result = office.run(type("Args", (), {"input": str(source), "output": str(destination), "command": "pdf"})())
            self.assertEqual(result["status"], "success")
            self.assertEqual(result["removed_defined_names"], 1)
            self.assertIn("external_hyperlinks", result["omissions"])
            text = "\n".join(page.extract_text() for page in PdfReader(destination).pages)
            self.assertIn("saved-only", text)
            self.assertEqual(requests, [])
            self.assertEqual(digest(source), before)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_limits_and_rejections_do_not_publish_a_result(self):
        source = self.source("limits")
        for index, setting in enumerate(["XML_BYTES", "TOTAL_XML_BYTES", "MAX_CELLS"]):
            output = self.root / f"limited-{index}"
            with patch.object(static, setting, 1):
                with self.assertRaises(ValueError):
                    office.run(type("Args", (), {"input": str(source), "output": str(output), "command": "render", "width": 640})())
            self.assertFalse(output.exists())
        existing = self.root / "existing.pdf"
        existing.write_bytes(b"retain")
        with self.assertRaises(ValueError):
            office.run(type("Args", (), {"input": str(source), "output": str(existing), "command": "pdf"})())
        self.assertEqual(existing.read_bytes(), b"retain")


if __name__ == "__main__":
    unittest.main()
