"""Qualify preview preparation with the component's real runtime and engine.

Run with office.exe python check-office-previews.py <component-root>.
--source explicitly tests checkout controller/helper sources against that
runtime; it does not qualify an immutable installed component or release.
"""
import argparse
from contextlib import redirect_stdout
import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

from openpyxl import Workbook
from PIL import Image
from defusedxml.common import DefusedXmlException

parser = argparse.ArgumentParser()
parser.add_argument("component", type=Path)
parser.add_argument("--source", action="store_true")
options, remaining = parser.parse_known_args()
sys.argv = [sys.argv[0], *remaining]
COMPONENT = options.component.resolve(strict=True)
REPO = Path(__file__).resolve().parents[1]
TOOLS = REPO / "src/product/skill/office_runtime" if options.source else COMPONENT / "tools"


def module(name, filename=None):
    spec = importlib.util.spec_from_file_location(name, TOOLS / (filename or name + ".py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    sys.modules[name] = value
    return value


preview = module("document_preview")
office = module("office_preview_controller", "office.py")
if options.source:
    # Explicit source qualification only; never alter the selected component's
    # immutable resources/manifest or pretend this is an installed release.
    office.ROOT = COMPONENT
    office.PROGRAM = COMPONENT / "engine/program"


def rewrite(source, destination, transform):
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as result:
        for item in original.infolist():
            result.writestr(item, transform(item.filename, original.read(item.filename)))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = REPO / ".zig-cache/office-preview-qualification"
        root.mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="source-" if options.source else "installed-", dir=root)
        cls.root = Path(cls.temporary.name)
        result = subprocess.run([str(COMPONENT / "bin/office.exe"), "node",
                                 str(REPO / "scripts/create-office-engine-fixtures.mjs"), str(cls.root)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError("Preview fixture creation failed")
        chart_script = cls.root / "chart.mjs"
        chart_script.write_text('''import pptxgen from "pptxgenjs";
const deck = new pptxgen();
const slide = deck.addSlide();
slide.addChart(deck.ChartType.bar, [{name:"Sales",labels:["Q1","Q2"],values:[12,24]}],
               {x:1,y:1,w:7,h:4,showTitle:true,title:"Chart 中文"});
await deck.writeFile({fileName:process.argv[2]});
''', encoding="utf-8")
        result = subprocess.run([str(COMPONENT / "bin/office.exe"), "node", str(chart_script),
                                 str(cls.root / "chart.pptx")], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError("Embedded chart fixture creation failed")
        cls.component_manifest = (COMPONENT / "office-runtime.json").read_bytes()

    @classmethod
    def tearDownClass(cls):
        if (COMPONENT / "office-runtime.json").read_bytes() != cls.component_manifest:
            raise AssertionError("Preview tests changed the component manifest")
        cls.temporary.cleanup()

    def run_preview(self, source, name):
        output = self.root / name
        result = office.run(SimpleNamespace(command="preview", input=str(source), output=str(output), width=640))
        self.assertEqual(result["status"], "success")
        manifest = json.loads((output / "preview.json").read_text(encoding="utf-8"))
        for resource in [manifest["sourceText"], *manifest.get("pages", []), *([manifest["grid"]] if "grid" in manifest else [])]:
            file = output / resource["file"]
            self.assertEqual(file.stat().st_size, resource["bytes"])
            self.assertEqual(digest(file), resource["sha256"])
        return output, manifest

    def workbook(self, name):
        workbook = Workbook()
        sheet = workbook.active
        sheet.title = "数据 中文"
        sheet["A1"] = "Name"
        sheet["A2"] = "示例"
        sheet["B2"] = 1234.5
        sheet["B2"].number_format = "#,##0.00"
        sheet["C2"] = 0.125
        sheet["C2"].number_format = "0.0%"
        sheet["D2"] = "=B2*2"
        sheet["E2"] = datetime.date(2026, 10, 23)
        sheet["F2"] = True
        sheet["G2"] = "#REF!"
        sheet["G2"].data_type = "e"
        sheet.merge_cells("A4:B4")
        hidden = workbook.create_sheet("Hidden")
        hidden.sheet_state = "hidden"
        hidden["A1"] = "Hidden content"
        file = self.root / name
        workbook.save(file)
        workbook.close()
        return file

    def test_grid_preserves_formulas_saved_values_hidden_sheets_and_common_formats_without_engine(self):
        source = self.workbook("grid-input.xlsx")
        before = digest(source)
        with patch.object(office, "Engine", side_effect=AssertionError("Grid must not start the conversion engine")):
            output, manifest = self.run_preview(source, "grid-preview")
        grid = json.loads((output / "grid.json").read_text(encoding="utf-8"))
        self.assertEqual(grid["calculation"], "saved_values_only")
        cells = {(cell["row"], cell["column"]): cell for cell in grid["sheets"][0]["cells"]}
        self.assertEqual(cells[2, 2]["display"], "1,234.50")
        self.assertEqual(cells[2, 3]["display"], "12.5%")
        self.assertEqual(cells[2, 4]["formula"], "=B2*2")
        self.assertIsNone(cells[2, 4]["value"])
        self.assertEqual(cells[2, 5]["value"]["text"], "2026-10-23T00:00:00")
        self.assertFalse(cells[2, 5]["formatSupported"])
        self.assertEqual(cells[2, 6]["value"], {"kind": "boolean", "text": "true"})
        self.assertEqual(cells[2, 7]["value"]["kind"], "error")
        self.assertTrue(grid["sheets"][1]["hidden"])
        self.assertIn("merged_cells", manifest["omissions"])
        self.assertIn("Hidden content", (output / "source-text.txt").read_text(encoding="utf-8"))
        self.assertEqual(digest(source), before)

    def test_grid_reads_actual_extent_and_cached_formula_value_despite_underreported_dimension(self):
        source = self.workbook("cache-original.xlsx")
        changed = self.root / "cache-input.xlsx"
        def transform(name, data):
            if name == "xl/worksheets/sheet1.xml":
                self.assertIn(b'<dimension ref="A1:G4"/>', data)
                data = data.replace(b'<dimension ref="A1:G4"/>', b'<dimension ref="A1:A1"/>')
                data = data.replace(b'<f>B2*2</f><v></v>', b'<f>B2*2</f><v>2469</v>')
            return data
        rewrite(source, changed, transform)
        output, _ = self.run_preview(changed, "cached-preview")
        grid = json.loads((output / "grid.json").read_text(encoding="utf-8"))
        cells = grid["sheets"][0]["cells"]
        formula = next(cell for cell in cells if cell["formula"])
        self.assertEqual(formula["value"], {"kind": "number", "text": "2469"})
        self.assertEqual(grid["sheets"][0]["columns"], 7)

    def test_source_text_rejoins_formatted_runs_decodes_xml_and_scans_attributes(self):
        source = self.root / "split.docx"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("word/document.xml", '''<w:document xmlns:w="urn:w"><w:p>
                <w:r><w:t>sk-中文&amp;</w:t></w:r>
                <w:r><w:rPr><w:b/></w:rPr><w:t>secret</w:t></w:r>
                </w:p><w:other value="attribute-secret"/></w:document>''')
        text, _ = preview.source_text(source)
        self.assertIn("sk-中文&secret".encode(), text)
        self.assertIn(b"attribute-secret", text)

    def test_external_resources_active_content_and_dtd_are_rejected_before_rendering(self):
        for index, (name, content) in enumerate([
            ("word/_rels/document.xml.rels", '<Relationships><Relationship Type="image" TargetMode="External" Target="https://example.invalid/image.png"/></Relationships>'),
            ("word/_rels/document.xml.rels", '<Relationships><Relationship Type="image" Target="https://example.invalid/image.png"/></Relationships>'),
            ("word/_rels/document.xml.rels", '<Relationships><Relationship Type="image" Target="../../../outside.png"/></Relationships>'),
            ("word/document.xml", '<!DOCTYPE doc [<!ENTITY x "secret">]><doc>&x;</doc>'),
            ("[Content_Types].xml", '<Types><Override PartName="/word/opaque.bin" ContentType="application/vnd.ms-office.vbaProject"/></Types>'),
            ("[Content_Types].xml", '<Types><Override PartName="/word/opaque.bin" ContentType="image/svg+xml"/></Types>'),
            ("[Content_Types].xml", '<Types><Override PartName="/word/opaque%2Ebin" ContentType="application/vnd.openxmlformats-officedocument.oleObject"/></Types>'),
            ("[Content_Types].xml", '<Types><Default Extension="bin" ContentType="application/vnd.openxmlformats-officedocument.oleObject"/></Types>'),
            ("word/embeddings/object.bin", "object"),
        ]):
            source = self.root / f"rejected-{index}.docx"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(name, content)
                if name == "[Content_Types].xml":
                    archive.writestr("word/opaque.bin", b"nonstandard part name")
            with self.assertRaises((ValueError, DefusedXmlException)):
                preview.source_text(source)

    def test_unused_default_types_are_safe_but_existing_default_active_parts_are_rejected(self):
        source = self.root / "unused-default.docx"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("[Content_Types].xml", '<Types><Default Extension="svg" ContentType="image/svg+xml"/></Types>')
        preview.source_text(source)
        with zipfile.ZipFile(source, "a") as archive:
            archive.writestr("word/media/icon.svg", b"<svg/>")
        with self.assertRaises(ValueError):
            preview.source_text(source)

    def test_raster_media_is_checked_by_actual_format_and_pixel_budget(self):
        png = io.BytesIO()
        Image.new("RGB", (2, 3), "blue").save(png, format="PNG")
        source = self.root / "raster.docx"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("word/media/picture.png", png.getvalue())
        preview.source_text(source)
        with patch.object(preview, "MAX_MEDIA_PIXELS", 1), self.assertRaises(ValueError):
            preview.source_text(source)
        disguised = self.root / "disguised.docx"
        with zipfile.ZipFile(disguised, "w") as archive:
            archive.writestr("word/media/picture.png", b'<svg xmlns="http://www.w3.org/2000/svg"/>')
        with self.assertRaises(OSError):
            preview.source_text(disguised)

    def test_embedded_chart_workbook_is_bounded_and_its_text_is_scanned(self):
        workbook = self.workbook("embedded.xlsx")
        presentation = self.root / "embedded.pptx"
        with zipfile.ZipFile(presentation, "w") as archive:
            archive.writestr("ppt/embeddings/", b"")
            archive.writestr("ppt/embeddings/chart.xlsx", workbook.read_bytes())
        text, _ = preview.source_text(presentation)
        self.assertIn(b"Hidden content", text)
        with patch.object(preview, "TEXT_BYTES", 2), self.assertRaises(ValueError):
            preview.source_text(presentation)
        invalid = self.root / "bad-embedded.pptx"
        with zipfile.ZipFile(invalid, "w") as archive:
            archive.writestr("ppt/embeddings/chart.xlsx", b"not an archive")
        with self.assertRaises(ValueError):
            preview.source_text(invalid)

    def test_source_text_and_grid_utf8_budgets_fail_without_publishing(self):
        source = self.workbook("budget-input.xlsx")
        for setting in ("TEXT_BYTES", "GRID_BYTES", "MAX_VISITED_CELLS", "MAX_COLUMNS", "MAX_CELL_BYTES"):
            with self.subTest(setting=setting), patch.object(preview, setting, 1):
                output = self.root / f"rejected-{setting}"
                with self.assertRaises(ValueError):
                    office.run(SimpleNamespace(command="preview", input=str(source), output=str(output), width=640))
                self.assertFalse(output.exists())
                self.assertFalse(list(self.root.glob(".metawork-office-*")))

    def test_docx_and_pptx_pages_render_once_and_reuse_verified_images(self):
        original_engine = office.Engine
        for filename in ("original.docx", "sample.pptx", "chart.pptx"):
            with self.subTest(filename=filename), patch.object(office, "Engine", wraps=original_engine) as engine:
                source = self.root / filename
                before = digest(source)
                output, manifest = self.run_preview(source, filename + "-preview")
                self.assertEqual(engine.call_count, 1)
                self.assertGreater(len(manifest["pages"]), 0)
                for page in reversed(manifest["pages"]):
                    with Image.open(output / page["file"]) as image:
                        self.assertEqual(image.size, (page["width"], page["height"]))
                        image.verify()
                self.assertEqual(engine.call_count, 1)
                self.assertEqual(digest(source), before)

    def test_page_budget_and_source_change_discard_the_entire_preparation(self):
        source = self.root / "original.docx"
        with patch.object(preview, "PAGE_BYTES", 1):
            with self.assertRaises(ValueError):
                office.run(SimpleNamespace(command="preview", input=str(source), output=str(self.root / "page-budget"), width=640))
        self.assertFalse((self.root / "page-budget").exists())
        mutable = self.root / "changing.xlsx"
        mutable.write_bytes(self.workbook("change-original.xlsx").read_bytes())
        prepare = preview.prepare
        def changed(*args):
            result = prepare(*args)
            with mutable.open("ab") as stream:
                stream.write(b"changed")
            return result
        with patch.object(preview, "prepare", side_effect=changed):
            with self.assertRaises(ValueError):
                office.run(SimpleNamespace(command="preview", input=str(mutable), output=str(self.root / "changed-preview"), width=640))
        self.assertFalse((self.root / "changed-preview").exists())
        self.assertFalse(list(self.root.glob(".metawork-office-*")))

    def test_cli_rejects_uncheckable_pdf_without_publishing_or_printing_source(self):
        source = self.root / "private-name.pdf"
        source.write_bytes(b"%PDF-1.4\n")
        output = self.root / "pdf-preview"
        stdout = io.StringIO()
        with patch.object(sys, "argv", ["office", "preview", str(source), str(output)]), redirect_stdout(stdout):
            self.assertEqual(office.main(), 1)
        self.assertEqual(json.loads(stdout.getvalue())["status"], "failed")
        self.assertNotIn("private-name", stdout.getvalue())
        self.assertFalse(output.exists())

    @unittest.skipIf(options.source, "Checkout-source mode does not qualify the installed entry command")
    def test_installed_entry_runs_the_preview_command_and_preserves_source_bytes(self):
        source = self.workbook("cli-input.xlsx")
        before = digest(source)
        output = self.root / "cli-preview"
        result = subprocess.run([str(COMPONENT / "bin/office.exe"), "preview", str(source), str(output)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"status": "success", "kind": "grid", "sheet_count": 2})
        self.assertEqual(json.loads((output / "preview.json").read_text(encoding="utf-8"))["kind"], "grid")
        self.assertEqual(digest(source), before)


if __name__ == "__main__":
    print("Preview qualification: " + ("checkout sources with real component runtime" if options.source else "installed component resources"), flush=True)
    unittest.main()
