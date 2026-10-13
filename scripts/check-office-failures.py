"""Failure-path checks for migrated helpers; run through office:check."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
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


class OfficeFailures(unittest.TestCase):
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
                with self.subTest(case=case), patch.object(recalc.subprocess, "run", **case):
                    self.assertIn("error", recalc.recalc(source, 1))
                    self.assertEqual(original, source.read_bytes())

    def test_tracked_changes_timeout_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.docx"
            source.write_bytes(b"timeout fixture")
            with patch.object(accept, "_setup_libreoffice_macro", return_value=True), patch.object(accept.subprocess, "run", side_effect=subprocess.TimeoutExpired("soffice", 30)):
                _, message = accept.accept_changes(str(source), str(Path(directory) / "result.docx"))
                self.assertTrue(message.startswith("Error:"))
                self.assertIn("timed out", message)


if __name__ == "__main__":
    unittest.main()
