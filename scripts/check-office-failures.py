"""Failure-path checks for migrated helpers; run through office:check."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch
from openpyxl import Workbook

assets = Path(sys.argv.pop(1))


def load(name, path):
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recalc = load("office_recalc", assets / "xlsx/scripts/recalc.py")
accept = load("office_accept", assets / "docx/scripts/accept_changes.py")
thumbnail = load("office_thumbnail", assets / "pptx/scripts/thumbnail.py")


class OfficeFailures(unittest.TestCase):
    def recalc_fixture(self, directory, formula="=1+1"):
        source = Path(directory) / "original.xlsx"
        workbook = Workbook()
        workbook.active["A1"] = formula
        workbook.active["B1"] = "Documentation mentioning #REF! is plain text"
        workbook.save(source)
        workbook.close()
        return source

    def conversion(self, source, change=None):
        def run(args, **kwargs):
            input_copy = Path(args[-1])
            self.assertNotEqual(input_copy, source)
            self.assertEqual(input_copy.read_bytes(), source.read_bytes())
            output = Path(args[args.index("--outdir") + 1]) / input_copy.name
            with zipfile.ZipFile(input_copy) as original, zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as result:
                for name in original.namelist():
                    data = original.read(name)
                    if name == "xl/worksheets/sheet1.xml":
                        root = ET.fromstring(data)
                        ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
                        cell = root.find(f".//{ns}c[@r='A1']")
                        cell.find(ns + "v").text = "2"
                        if change:
                            change(cell, ns)
                        data = ET.tostring(root)
                    result.writestr(name, data)
            return subprocess.CompletedProcess(args, 0, "", "")
        return run

    def test_recalculation_failure_preserves_original(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.xlsx"
            workbook = Workbook()
            workbook.active["A1"] = "=1+1"
            workbook.save(source)
            workbook.close()
            original = source.read_bytes()
            cases = [
                {"side_effect": subprocess.TimeoutExpired("soffice", 1)},
                {"return_value": subprocess.CompletedProcess("soffice", 1, "", "conversion failed")},
                {"return_value": subprocess.CompletedProcess("soffice", 0, "", "")},
            ]
            for case in cases:
                with self.subTest(case=case), patch.object(recalc.subprocess, "run", **case) as process:
                    self.assertIn("error", recalc.recalc(source, 1))
                    process.assert_called_once()
                    self.assertEqual(original, source.read_bytes())

    def test_tracked_changes_timeout_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.docx"
            source.write_bytes(b"timeout fixture")
            with patch.object(accept, "_setup_libreoffice_macro", return_value=True), patch.object(accept.subprocess, "run", side_effect=subprocess.TimeoutExpired("soffice", 30)):
                _, message = accept.accept_changes(str(source), str(Path(directory) / "result.docx"))
                self.assertTrue(message.startswith("Error:"))
                self.assertIn("timed out", message)

    def test_formula_loss_change_and_missing_cache_never_replace_source(self):
        cases = {
            "lost": lambda cell, ns: cell.remove(cell.find(ns + "f")),
            "changed": lambda cell, ns: setattr(cell.find(ns + "f"), "text", "1+2"),
            "missing cache": lambda cell, ns: cell.remove(cell.find(ns + "v")),
            "empty numeric cache": lambda cell, ns: setattr(cell.find(ns + "v"), "text", None),
        }
        with tempfile.TemporaryDirectory() as directory:
            source = self.recalc_fixture(directory)
            original = source.read_bytes()
            before = set(Path(directory).iterdir())
            for name, change in cases.items():
                with self.subTest(name=name), patch.object(recalc.subprocess, "run", side_effect=self.conversion(source, change)) as process:
                    self.assertIn("error", recalc.recalc(source))
                    process.assert_called_once()
                    self.assertEqual(source.read_bytes(), original)
                    self.assertEqual(set(Path(directory).iterdir()), before)

    def test_valid_result_preserves_formulas_and_reports_only_actual_excel_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.recalc_fixture(directory)
            with patch.object(recalc.subprocess, "run", side_effect=self.conversion(source)):
                result = recalc.recalc(source)
            self.assertEqual(result, {"status": "success", "total_errors": 0, "error_summary": {}, "total_formulas": 1})
            self.assertEqual(recalc._formulas(source), {("Sheet", "A1"): "=1+1"})
            workbook = recalc.load_workbook(source, data_only=True)
            self.assertEqual(workbook.active["A1"].value, 2)
            workbook.close()

    def test_empty_string_cache_is_a_saved_result(self):
        def empty(cell, ns):
            cell.set("t", "str")
            cell.find(ns + "v").text = None
        with tempfile.TemporaryDirectory() as directory:
            source = self.recalc_fixture(directory, '=""')
            with patch.object(recalc.subprocess, "run", side_effect=self.conversion(source, empty)):
                self.assertEqual(recalc.recalc(source).get("status"), "success")

    def test_source_changed_during_conversion_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.recalc_fixture(directory)
            convert = self.conversion(source)
            def run(*args, **kwargs):
                result = convert(*args, **kwargs)
                source.write_bytes(b"concurrent user edit")
                return result
            with patch.object(recalc.subprocess, "run", side_effect=run):
                self.assertIn("changed during recalculation", recalc.recalc(source).get("error", ""))
            self.assertEqual(source.read_bytes(), b"concurrent user edit")

    def test_formula_errors_are_reported_as_errors_instead_of_success(self):
        def formula_error(cell, ns):
            cell.set("t", "e")
            cell.find(ns + "v").text = "#DIV/0!"
        with tempfile.TemporaryDirectory() as directory:
            source = self.recalc_fixture(directory, "=1/0")
            with patch.object(recalc.subprocess, "run", side_effect=self.conversion(source, formula_error)):
                result = recalc.recalc(source)
            self.assertEqual(result["status"], "errors_found")
            self.assertEqual(result["error_summary"], {"#DIV/0!": {"count": 1, "locations": ["Sheet!A1"]}})

    def test_linux_shim_is_not_used_on_windows_or_macos(self):
        from office import soffice
        for platform in ("win32", "darwin"):
            with patch.object(soffice.sys, "platform", platform), patch.object(soffice.socket, "socket") as socket:
                self.assertFalse(soffice._needs_shim())
                socket.assert_not_called()

    def test_unsafe_archive_and_excessive_cell_range_do_not_start_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.recalc_fixture(directory)
            with zipfile.ZipFile(source, "a") as archive:
                archive.writestr("../escape", "bad")
            before = source.read_bytes()
            with patch.object(recalc.subprocess, "run") as process:
                self.assertIn("error", recalc.recalc(source))
                process.assert_not_called()
            self.assertEqual(source.read_bytes(), before)
            workbook = Workbook()
            workbook.active["A1000001"] = "=1+1"
            workbook.save(source)
            workbook.close()
            with patch.object(recalc.subprocess, "run") as process:
                self.assertIn("cell budget", recalc.recalc(source).get("error", ""))
                process.assert_not_called()


class ThumbnailInputs(unittest.TestCase):
    def make_deck(self, root, target="slides/slide2.xml", extra=()):
        deck = Path(root) / "sample.pptx"
        entries = {
            "ppt/_rels/presentation.xml.rels": f'''<Relationships>
              <Relationship Id="visible" Type="http://example/slide" Target="slides/slide1.xml"/>
              <Relationship Id="hidden" Type="http://example/slide" Target="{target}"/>
            </Relationships>''',
            "ppt/presentation.xml": '''<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:sldIdLst><p:sldId r:id="hidden"/><p:sldId r:id="visible"/></p:sldIdLst>
            </p:presentation>''',
            "ppt/slides/slide1.xml": '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>',
            "ppt/slides/slide2.xml": '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" show="false"/>',
        }
        entries.update(extra)
        with zipfile.ZipFile(deck, "w", zipfile.ZIP_DEFLATED) as output:
            for name, content in entries.items():
                output.writestr(name, content)
        return deck

    def test_slide_order_and_hidden_property_come_from_the_document(self):
        with tempfile.TemporaryDirectory() as directory:
            deck = self.make_deck(directory)
            self.assertEqual(thumbnail.get_slide_info(deck), [
                {"name": "slide2.xml", "hidden": True}, {"name": "slide1.xml", "hidden": False}])

    def test_unsafe_relationship_or_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for target in ("slides/../../escape.xml", "slides/../escape.xml", "/outside.xml"):
                with self.subTest(target=target), self.assertRaises(ValueError):
                    thumbnail.get_slide_info(self.make_deck(directory, target))
            with self.assertRaises(ValueError):
                thumbnail.get_slide_info(self.make_deck(directory, extra={"../escape": "bad"}))

    def test_missing_visible_render_is_not_silently_dropped(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "page count"):
                thumbnail.build_slide_list([{"name": "slide1.xml", "hidden": False}], [], Path(directory))

    def test_cli_metadata_and_conversion_use_the_same_checked_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deck = self.make_deck(root)
            original = deck.read_bytes()
            seen = []
            inspect = thumbnail.get_slide_info
            def info(path):
                self.assertNotEqual(path, deck)
                seen.append(path)
                result = inspect(path)
                deck.write_bytes(b"user changed original after preparation")
                return result
            def render(path, temporary):
                self.assertEqual(path, seen[0])
                self.assertEqual(path.read_bytes(), original)
                image = temporary / "visible.jpg"
                with thumbnail.Image.new("RGB", (40, 30), "white") as content:
                    content.save(image)
                return [image]
            with patch.object(thumbnail, "get_slide_info", side_effect=info), patch.object(thumbnail, "convert_to_images", side_effect=render), patch.object(sys, "argv", ["thumbnail.py", str(deck), str(root / "grid")]):
                thumbnail.main()
            self.assertTrue((root / "grid.jpg").is_file())
            self.assertFalse(seen[0].parent.exists())



if __name__ == "__main__":
    unittest.main()
