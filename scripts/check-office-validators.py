"""Exercise original-document readers as well as the packed validation CLI."""
import subprocess
import dataclasses
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

OFFICE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(OFFICE))

from archive import ArchiveError
import pack as pack_module
from helpers.simplify_redlines import _get_authors_from_docx
from validators import DOCXSchemaValidator, RedliningValidator

XML = b'''<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:ins w:author="Alice"><w:r><w:t>content</w:t></w:r></w:ins></w:p></w:body>
</w:document>'''


class OriginalReaders(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.modified = self.root / "modified"
        (self.modified / "word").mkdir(parents=True)
        (self.modified / "word/document.xml").write_bytes(XML)
        self.original = self.root / "original.docx"

    def tearDown(self):
        self.scratch.cleanup()

    def original_zip(self, entries):
        with zipfile.ZipFile(self.original, "w", zipfile.ZIP_DEFLATED) as output:
            for name, content in entries:
                output.writestr(name, content)

    def test_valid_original_preserves_paragraphs_and_authors(self):
        self.original_zip([("word/document.xml", XML)])
        validator = DOCXSchemaValidator(self.modified, self.original)
        self.assertEqual(validator.count_paragraphs_in_original(), 1)
        self.assertEqual(_get_authors_from_docx(self.original), {"Alice": 1})

    def test_all_original_readers_reject_traversal(self):
        self.original_zip([("word/document.xml", XML), ("../escape", b"bad")])
        validator = DOCXSchemaValidator(self.modified, self.original)
        with self.assertRaises(ValueError):
            validator.count_paragraphs_in_original()
        with self.assertRaises(ArchiveError):
            validator._get_original_file_errors(self.modified / "word/document.xml")
        with self.assertRaises(ArchiveError):
            RedliningValidator(self.modified, self.original, author="Alice").validate()
        with self.assertRaises(ArchiveError):
            _get_authors_from_docx(self.original)
        self.assertFalse((self.root / "escape").exists())

    def test_invalid_original_is_not_reported_as_no_authors(self):
        self.original.write_bytes(b"not a document")
        with self.assertRaises(ArchiveError):
            _get_authors_from_docx(self.original)

    def test_packed_cli_rejects_traversal_and_cleans_temporary_directory(self):
        self.original_zip([("word/document.xml", XML), ("../escape", b"bad")])
        before = set(self.root.iterdir())
        import os
        result = subprocess.run(
            [sys.executable, "-B", str(OFFICE / "validate.py"), str(self.original)],
            env={**os.environ, "TMP": str(self.root), "TEMP": str(self.root), "TMPDIR": str(self.root)},
            capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Unsafe ZIP path", result.stderr)
        self.assertEqual(set(self.root.iterdir()), before)

    def test_xsd_original_comparison_consumes_checked_extraction_and_releases_it(self):
        self.original_zip([("word/document.xml", XML)])
        validator = DOCXSchemaValidator(self.modified, self.original)
        observed = []
        def check(xml_file, root):
            observed.append(root)
            self.assertEqual(xml_file.read_bytes(), XML)
            return False, {"existing error"}
        with patch.object(validator, "_validate_single_file_xsd", side_effect=check):
            self.assertEqual(validator._get_original_file_errors(
                self.modified / "word/document.xml"), {"existing error"})
        self.assertEqual(len(observed), 1)
        self.assertFalse(observed[0].parent.exists())

    def test_pack_missing_original_and_original_overwrite_are_explicit_failures(self):
        output = self.root / "result.docx"
        output.write_bytes(b"existing output")
        _, message = pack_module.pack(str(self.modified), str(output), str(self.original))
        self.assertTrue(message.startswith("Error:"), message)
        self.assertEqual(output.read_bytes(), b"existing output")
        self.original_zip([("word/document.xml", XML)])
        before = self.original.read_bytes()
        _, message = pack_module.pack(str(self.modified), str(self.original), str(self.original))
        self.assertIn("cannot overwrite", message)
        self.assertEqual(self.original.read_bytes(), before)

    def test_pack_repairs_only_a_private_copy_and_publishes_readable_zip(self):
        original_xml = (self.modified / "word/document.xml").read_bytes()
        observed = []
        def repair(private, original, suffix, infer_author):
            observed.append(private)
            (private / "word/document.xml").write_bytes(XML.replace(b"content", b"repaired"))
            return True, None
        output = self.root / "result.docx"
        with patch.object(pack_module, "_run_validation", side_effect=repair):
            _, message = pack_module.pack(str(self.modified), str(output))
        self.assertTrue(message.startswith("Successfully"), message)
        self.assertEqual((self.modified / "word/document.xml").read_bytes(), original_xml)
        with zipfile.ZipFile(output) as packed:
            self.assertIn(b"repaired", packed.read("word/document.xml"))
            self.assertIsNone(packed.testzip())
        self.assertFalse(observed[0].parent.exists())

    def test_pack_validation_and_mid_write_failure_preserve_existing_output(self):
        output = self.root / "result.docx"
        output.write_bytes(b"existing output")
        original_xml = (self.modified / "word/document.xml").read_bytes()
        before = set(self.root.iterdir())
        with patch.object(pack_module, "_run_validation", return_value=(False, "invalid")):
            _, message = pack_module.pack(str(self.modified), str(output))
            self.assertTrue(message.startswith("Error:"), message)
        write = zipfile.ZipFile.write
        def fail_after_write(archive, *args, **kwargs):
            write(archive, *args, **kwargs)
            raise OSError("simulated disk failure")
        with patch.object(zipfile.ZipFile, "write", fail_after_write):
            _, message = pack_module.pack(str(self.modified), str(output), validate=False)
            self.assertIn("simulated disk failure", message)
        self.assertEqual(output.read_bytes(), b"existing output")
        self.assertEqual((self.modified / "word/document.xml").read_bytes(), original_xml)
        self.assertEqual(set(self.root.iterdir()), before)

    def test_pack_rejects_output_inside_source_tree(self):
        output = self.modified / "result.docx"
        _, message = pack_module.pack(str(self.modified), str(output), validate=False)
        self.assertTrue(message.startswith("Error:"), message)
        self.assertFalse(output.exists())

    def test_pack_rejects_work_copy_over_budget_and_original_hardlink(self):
        output = self.root / "result.docx"
        limits = dataclasses.replace(pack_module.DEFAULT_LIMITS, total_bytes=4)
        with patch.object(pack_module, "DEFAULT_LIMITS", limits):
            _, message = pack_module.pack(str(self.modified), str(output), validate=False)
        self.assertIn("budget exceeded", message)
        self.assertFalse(output.exists())
        self.original_zip([("word/document.xml", XML)])
        original = self.original.read_bytes()
        os.link(self.original, output)
        _, message = pack_module.pack(str(self.modified), str(output), str(self.original))
        self.assertIn("cannot overwrite", message)
        self.assertEqual(self.original.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
