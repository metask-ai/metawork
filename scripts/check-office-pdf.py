"""PDF inspection qualification with the selected component's Python.

--source permits checkout code and an explicitly pinned wheel for development;
it never changes or qualifies the immutable installed component.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

parser = argparse.ArgumentParser()
parser.add_argument("component", type=Path)
parser.add_argument("--source", action="store_true")
parser.add_argument("--pypdf-wheel", type=Path)
options, remaining = parser.parse_known_args()
sys.argv = [sys.argv[0], *remaining]
root = Path(__file__).resolve().parents[1]
component = options.component.resolve(strict=True)
if options.pypdf_wheel:
    if not options.source:
        raise ValueError("External wheel is only permitted for explicit source qualification")
    wheel = options.pypdf_wheel.resolve(strict=True)
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != "1d44d1a3a200f25062adff0085b02040e4646431ac2ccac22e42679e91466084":
        raise ValueError("PDF qualification wheel identity mismatch")
    sys.path.insert(0, str(wheel))
tools = root / "src/product/skill/office_runtime" if options.source else component / "tools"
spec = importlib.util.spec_from_file_location("pdf_source", tools / "pdf_source.py")
pdf = importlib.util.module_from_spec(spec)
sys.modules["pdf_source"] = pdf
spec.loader.exec_module(pdf)

from pypdf import PdfWriter, apply_configuration
from pypdf.generic import ArrayObject, DecodedStreamObject, EncodedStreamObject, DictionaryObject, NameObject, NumberObject, TextStringObject

SECRET = "metawork-pdf-synthetic-credential"


def document(path, contents=None, mutate=None):
    writer = PdfWriter()
    page = writer.add_blank_page(600, 800)
    font = DictionaryObject({NameObject("/Type"): NameObject("/Font"),
                             NameObject("/Subtype"): NameObject("/Type1"),
                             NameObject("/BaseFont"): NameObject("/Helvetica")})
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})})
    stream = DecodedStreamObject()
    stream.set_data(contents or b"BT /F1 12 Tf 20 700 Td (PDF preview) Tj ET")
    page[NameObject("/Contents")] = stream
    if mutate:
        mutate(writer, page)
    writer.write(path)


class PdfTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="mw-pdf-")
        self.path = Path(self.scratch.name) / "sample.pdf"

    def tearDown(self):
        self.scratch.cleanup()

    def extract(self, maximum=4 * 1024 * 1024):
        return pdf.extract(self.path, maximum)

    def test_split_invisible_text_and_metadata_are_inspected(self):
        # Tr=3 is invisible; extraction must not discard it using coordinates.
        document(self.path, b"BT /F1 12 Tf 3 Tr 20 700 Td (metawork-pdf-) Tj (synthetic-credential) Tj ET",
                 lambda writer, page: writer.add_metadata({"/Subject": "metadata-" + SECRET}))
        before = self.path.read_bytes()
        text, omissions, count = self.extract()
        self.assertIn(SECRET.encode(), text)
        self.assertIn(("metadata-" + SECRET).encode(), text)
        self.assertEqual((omissions, count), ([], 1))
        self.assertEqual(before, self.path.read_bytes())

    def test_rejects_script_encryption_unknown_actions_and_external_streams(self):
        for change in (
            lambda writer, page: writer.add_js("app.alert('not executed')"),
            lambda writer, page: writer.encrypt("not-a-real-password"),
            lambda writer, page: page.update({NameObject("/A"): DictionaryObject({NameObject("/S"): NameObject("/UnknownAction")})}),
            lambda writer, page: page["/Contents"].update({NameObject("/F"): TextStringObject("file:///not-opened")}),
        ):
            with self.subTest(change=change):
                document(self.path, mutate=change)
                with self.assertRaises(Exception):
                    self.extract()

    def test_rejects_attachments_forms_unmapped_fonts_and_excess_pages(self):
        changes = [
            lambda writer, page: writer.add_attachment("not-opened.txt", b"payload"),
            lambda writer, page: writer._root_object.update({NameObject("/AcroForm"): DictionaryObject()}),
            lambda writer, page: page["/Resources"]["/Font"]["/F1"].update({NameObject("/Subtype"): NameObject("/Type3")}),
            lambda writer, page: [writer.add_blank_page(100, 100) for _ in range(100)],
        ]
        for change in changes:
            with self.subTest(change=change):
                document(self.path, mutate=change)
                with self.assertRaises(Exception):
                    self.extract()

    def test_tagged_document_attributes_are_not_executable_actions(self):
        def structure(writer, page):
            writer._root_object[NameObject("/StructTreeRoot")] = DictionaryObject({
                NameObject("/Type"): NameObject("/StructTreeRoot"),
                NameObject("/K"): DictionaryObject({NameObject("/Type"): NameObject("/StructElem"),
                    NameObject("/S"): NameObject("/P"), NameObject("/Alt"): TextStringObject(SECRET),
                    NameObject("/A"): DictionaryObject({NameObject("/O"): NameObject("/Layout")})})})
        document(self.path, mutate=structure)
        self.assertIn(SECRET.encode(), self.extract()[0])

    def test_uri_is_only_reported_and_its_text_is_checked(self):
        def link(writer, page):
            page[NameObject("/Annots")] = ArrayObject([DictionaryObject({
                NameObject("/Type"): NameObject("/Annot"), NameObject("/Subtype"): NameObject("/Link"),
                NameObject("/A"): DictionaryObject({NameObject("/S"): NameObject("/URI"),
                    NameObject("/URI"): TextStringObject("https://example.invalid/" + SECRET)})})])
        document(self.path, mutate=link)
        text, omissions, _ = self.extract()
        self.assertIn(SECRET.encode(), text)
        self.assertEqual(omissions, ["external_hyperlinks"])

    def test_xmp_strings_and_attributes_are_checked_and_entities_rejected(self):
        def metadata(data):
            def change(writer, page):
                stream = DecodedStreamObject()
                stream.set_data(data)
                stream.update({NameObject("/Type"): NameObject("/Metadata"), NameObject("/Subtype"): NameObject("/XML")})
                writer._root_object[NameObject("/Metadata")] = stream
            return change
        document(self.path, mutate=metadata(f'<root attribute="attr-{SECRET}">text-{SECRET}</root>'.encode()))
        text, _, _ = self.extract()
        self.assertIn(("attr-" + SECRET).encode(), text)
        self.assertIn(("text-" + SECRET).encode(), text)
        document(self.path, mutate=metadata(b'<root>metawork-pdf-<span format="normal">synthetic-credential</span></root>'))
        self.assertIn(SECRET.encode(), self.extract()[0])
        document(self.path, mutate=metadata(b'<!DOCTYPE root [<!ENTITY x "payload">]><root>&x;</root>'))
        with self.assertRaises(Exception):
            self.extract()

    def test_real_engine_chinese_and_multiple_pages(self):
        directory = Path(self.scratch.name)
        created = subprocess.run([str(component / "bin/office.exe"), "node",
                                  str(root / "scripts/create-office-engine-fixtures.mjs"), str(directory)],
                                 capture_output=True, text=True, timeout=60)
        self.assertEqual(created.returncode, 0, "Independent Office fixture creation failed")
        engine_spec = importlib.util.spec_from_file_location("pdf_engine_controller", tools / "office.py")
        office = importlib.util.module_from_spec(engine_spec)
        engine_spec.loader.exec_module(office)
        if options.source:
            office.ROOT = component
            office.PROGRAM = component / "engine/program"
        source = directory / "original.docx"
        with office.Engine(directory) as engine:
            loaded = engine.load(source)
            engine.pdf(loaded, self.path, ".docx")
        text, _, pages = self.extract()
        self.assertGreaterEqual(pages, 2)
        self.assertIn("中文".encode(), text)
        self.assertIn(b"Paragraph", text)
        preview_spec = importlib.util.spec_from_file_location("document_preview", tools / "document_preview.py")
        preview = importlib.util.module_from_spec(preview_spec)
        preview_spec.loader.exec_module(preview)
        output = directory / "preview"
        render_root = directory / "render-job"
        render_root.mkdir()
        outcome = preview.prepare(self.path, output, 640, lambda: office.Engine(render_root), office.render)
        import json
        manifest = json.loads((output / "preview.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["format"], "pdf")
        self.assertEqual(manifest["textScope"], pdf.SCOPE)
        self.assertEqual(outcome["page_count"], pages)
        self.assertEqual(len(manifest["pages"]), pages)
        self.assertIn("中文".encode(), (output / "source-text.txt").read_bytes())

    def test_input_cannot_invoke_an_external_jbig2_decoder(self):
        def external_filter(writer, page):
            stream = EncodedStreamObject()
            stream._data = b"not an image"
            stream[NameObject("/Filter")] = NameObject("/JBIG2Decode")
            page[NameObject("/Contents")] = stream
        document(self.path, mutate=external_filter)
        with apply_configuration(jbig2dec_binary="must-not-run.exe"), patch("pypdf.filters.subprocess.run") as spawned:
            with self.assertRaises(Exception):
                self.extract()
            spawned.assert_not_called()

    def test_complexity_text_and_decompression_budgets_reject(self):
        document(self.path)
        with self.assertRaises(Exception):
            self.extract(8)
        document(self.path, contents=b" " * (pdf.MAX_STREAM + 1))
        with self.assertRaises(Exception):
            self.extract()
        document(self.path, contents=b" " * (pdf.MAX_STREAM + 1), mutate=lambda writer, page: page.update({NameObject("/Contents"): page["/Contents"].flate_encode()}))
        with self.assertRaises(Exception):
            self.extract()
        self.path.write_bytes(b"%PDF-1.7\ninvalid")
        with self.assertRaises(Exception):
            self.extract()


if __name__ == "__main__":
    unittest.main()
