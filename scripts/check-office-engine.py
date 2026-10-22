"""Qualify a prepared Windows Office component against real user behaviors.

Usage: python check-office-engine.py <prepared-component-root>
Requires this checkout's Node authoring packages plus openpyxl and Pillow for
fixture creation/independent output checks. It never installs a system Office.
"""
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
import zipfile

from openpyxl import Workbook, load_workbook
from PIL import Image

if os.name != "nt":
    raise SystemExit("Office engine qualification requires Windows")
COMPONENT = Path(sys.argv.pop(1)).resolve(strict=True)
ROOT = Path(__file__).resolve().parents[1]
NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
kernel = ctypes.WinDLL("kernel32", use_last_error=True)


class ProcessEntry(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("usage", wintypes.DWORD),
                ("pid", wintypes.DWORD), ("heap", ctypes.c_size_t),
                ("module", wintypes.DWORD), ("threads", wintypes.DWORD),
                ("parent", wintypes.DWORD), ("priority", wintypes.LONG),
                ("flags", wintypes.DWORD), ("exe", wintypes.WCHAR * 260)]


kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
kernel.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]


def process_tree(pid):
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = ProcessEntry()
        entry.size = ctypes.sizeof(entry)
        processes = []
        valid = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while valid:
            processes.append((entry.pid, entry.parent, entry.exe))
            valid = kernel.Process32NextW(snapshot, ctypes.byref(entry))
        children = {}
        parents = {pid}
        while True:
            found = [(child, name) for child, parent, name in processes
                     if parent in parents and child not in children and child != pid]
            if not found:
                return children
            children.update(found)
            parents.update(child for child, _ in found)
    finally:
        kernel.CloseHandle(snapshot)


def word_text(root):
    return "".join(element.text or "" for element in root.iter(NS + "t"))


def add_revisions(original, output):
    with zipfile.ZipFile(original) as archive:
        parts = {name: archive.read(name) for name in archive.namelist()}
    root = ET.fromstring(parts["word/document.xml"])
    body = root.find(NS + "body")
    paragraphs = body.findall(NS + "p")
    revision = {NS + "id": "1", NS + "author": "MetaWork fixture",
                NS + "date": "2026-01-01T00:00:00Z"}
    paragraph = paragraphs[1]
    for run in list(paragraph.findall(NS + "r")):
        paragraph.remove(run)

    def text_run(parent, text, deleted=False):
        run = ET.SubElement(parent, NS + "r")
        value = ET.SubElement(run, NS + ("delText" if deleted else "t"))
        value.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        value.text = text
        return run

    text_run(paragraph, "Keep ")
    text_run(ET.SubElement(paragraph, NS + "del", revision), "delete ", True)
    text_run(ET.SubElement(paragraph, NS + "ins", {**revision, NS + "id": "2"}), "accepted ")
    text_run(paragraph, "insert.")
    properties = ET.SubElement(paragraphs[2], NS + "pPr")
    run_properties = ET.SubElement(properties, NS + "rPr")
    ET.SubElement(run_properties, NS + "del", {**revision, NS + "id": "3"})
    properties = paragraphs[0].find(NS + "r/" + NS + "rPr")
    previous = ET.SubElement(properties, NS + "rPrChange", {**revision, NS + "id": "4"})
    ET.SubElement(previous, NS + "rPr")
    table = body.find(NS + "tbl")
    rows = table.findall(NS + "tr")
    for row, name, number in [(rows[1], "del", "5"), (rows[2], "ins", "6")]:
        properties = row.find(NS + "trPr")
        if properties is None:
            properties = ET.SubElement(row, NS + "trPr")
        ET.SubElement(properties, NS + name, {**revision, NS + "id": number})
        if name == "del":
            # A deleted row and its deleted content form the representative
            # complete change. Bare trPr deletion is a separate unsupported
            # fidelity case and must not silently stand in for this fixture.
            p = row.find(".//" + NS + "p")
            for run in list(p.findall(NS + "r")):
                p.remove(run)
            text_run(ET.SubElement(p, NS + "del", {**revision, NS + "id": "7"}),
                     "Removed row", True)
    parts["word/document.xml"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    for name, data in list(parts.items()):
        if name.startswith("word/header") and name.endswith(".xml"):
            root = ET.fromstring(data)
            paragraph = root.find(NS + "p")
            text_run(ET.SubElement(paragraph, NS + "ins", {**revision, NS + "id": "8"}),
                     " Header accepted 页眉")
            parts[name] = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, data)


class OfficeEngine(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = ROOT / ".zig-cache/office-engine-regression"
        base.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="验收 文档 ", dir=base)
        cls.root = Path(cls.temporary.name)
        cls.exe = COMPONENT / "bin/office.exe"
        subprocess.run([str(cls.exe), "node", str(ROOT / "scripts/create-office-engine-fixtures.mjs"),
                        str(cls.root)], cwd=ROOT, check=True, timeout=30)
        add_revisions(cls.root / "original.docx", cls.root / "revisions.docx")
        for filename, formula in [("sample.xlsx", "=SUM(A1:B1)"), ("error.xlsx", "=1/0")]:
            workbook = Workbook()
            workbook.active["A1"] = 5
            workbook.active["B1"] = 7
            workbook.active["C1"] = formula
            workbook.active["A2"] = "中文单元格"
            workbook.save(cls.root / filename)
            workbook.close()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def invoke(self, command, source, output, *options, success=True):
        source = self.root / source
        original = source.read_bytes()
        process = subprocess.run([str(self.exe), command, str(source), str(self.root / output), *options],
                                 capture_output=True, text=True, encoding="utf-8", timeout=140)
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(process.stderr, "")
        if success:
            self.assertEqual(process.returncode, 0, process.stdout)
            self.assertEqual(json.loads(process.stdout)["status"], "success")
        else:
            self.assertNotEqual(process.returncode, 0)
        return process

    def assert_pages(self, directory, expected):
        root = self.root / directory
        manifest = json.loads((root / "pages.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(len(manifest["pages"]), expected)
        hashes = []
        for page in manifest["pages"]:
            data = (root / page["file"]).read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(digest, page["sha256"])
            hashes.append(digest)
            with Image.open(root / page["file"]) as image:
                self.assertEqual(image.format, "PNG")
                self.assertEqual(image.size, (page["width"], page["height"]))
                self.assertIsNotNone(image.convert("L").getextrema())
                self.assertLess(image.convert("L").getextrema()[0], 100)
        self.assertEqual(len(set(hashes)), expected, "Distinct fixture pages rendered as duplicate images")

    def test_accepts_run_paragraph_table_format_and_header_revisions(self):
        self.invoke("accept", "revisions.docx", "accepted.docx")
        with zipfile.ZipFile(self.root / "accepted.docx") as archive:
            document = ET.fromstring(archive.read("word/document.xml"))
            text = word_text(document)
            self.assertIn("Keep accepted insert.", text)
            self.assertNotIn("delete", text)
            self.assertNotIn("Removed row", text)
            self.assertIn("Added row", text)
            self.assertIn("Windows Office 中文验收", text)
            body = document.find(NS + "body")
            paragraphs = [word_text(p) for p in body.findall(NS + "p")]
            self.assertIn("Paragraph AParagraph B", paragraphs)
            self.assertEqual(len(body.find(NS + "tbl").findall(NS + "tr")), 2)
            title = body.find(NS + "p")
            self.assertIsNotNone(title.find(".//" + NS + "b"))
            header = "".join(word_text(ET.fromstring(archive.read(name))) for name in archive.namelist()
                             if name.startswith("word/header") and name.endswith(".xml"))
            self.assertIn("Header accepted 页眉", header)
            for name in archive.namelist():
                if name.startswith("word/") and name.endswith(".xml"):
                    root = ET.fromstring(archive.read(name))
                    self.assertFalse(any(element.tag in {NS + suffix for suffix in (
                        "ins", "del", "rPrChange", "pPrChange", "trPrChange")} for element in root.iter()))

    def test_recalculates_real_cache_and_preserves_formula(self):
        self.invoke("recalc", "sample.xlsx", "calculated.xlsx")
        formulas = load_workbook(self.root / "calculated.xlsx", data_only=False)
        values = load_workbook(self.root / "calculated.xlsx", data_only=True)
        try:
            self.assertEqual(formulas.active["C1"].value, "=SUM(A1:B1)")
            self.assertEqual(values.active["C1"].value, 12)
            self.assertEqual(values.active["A2"].value, "中文单元格")
        finally:
            formulas.close()
            values.close()

    def test_formula_error_is_reported_instead_of_success(self):
        result = self.invoke("recalc", "error.xlsx", "error-result.xlsx", success=False)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["status"], "errors_found")
        self.assertEqual(summary["total_errors"], 1)
        self.assertIn("#DIV/0!", summary["error_summary"])

    def test_word_pptx_and_pdf_have_distinct_complete_pages(self):
        self.invoke("render", "original.docx", "word-pages")
        self.assert_pages("word-pages", 2)
        self.invoke("render", "sample.pptx", "slide-pages")
        self.assert_pages("slide-pages", 3)
        self.invoke("pdf", "original.docx", "exported.pdf")
        self.assertTrue((self.root / "exported.pdf").read_bytes().startswith(b"%PDF-"))
        self.invoke("render", "exported.pdf", "pdf-pages")
        self.assert_pages("pdf-pages", 2)
        self.invoke("render", "sample.xlsx", "workbook-pages")
        self.assert_pages("workbook-pages", 1)

    def test_parallel_operations_use_independent_profiles(self):
        processes = []
        for name in ("parallel-one.pdf", "parallel-two.pdf"):
            process = subprocess.Popen([str(self.exe), "pdf", str(self.root / "original.docx"),
                                        str(self.root / name)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.addCleanup(self.stop_process, process)
            processes.append(process)
        for process in processes:
            stdout, stderr = process.communicate(timeout=90)
            self.assertEqual(process.returncode, 0, stdout)
            self.assertEqual(stderr, b"")
        for name in ("parallel-one.pdf", "parallel-two.pdf"):
            self.assertTrue((self.root / name).read_bytes().startswith(b"%PDF-"))

    def test_existing_output_and_corrupt_input_never_publish(self):
        destination = self.root / "existing.docx"
        destination.write_bytes(b"existing result")
        self.invoke("accept", "revisions.docx", destination.name, success=False)
        self.assertEqual(destination.read_bytes(), b"existing result")
        (self.root / "corrupt.docx").write_bytes(b"not an OOXML archive")
        self.invoke("accept", "corrupt.docx", "failed.docx", success=False)
        self.assertFalse((self.root / "failed.docx").exists())

    def test_word_and_presentation_structured_reads_keep_context(self):
        self.invoke("text", "revisions.docx", "word-text.json")
        word = json.loads((self.root / "word-text.json").read_text(encoding="utf-8"))
        self.assertEqual(word["format"], "docx")
        body = next(part["blocks"] for part in word["parts"] if part["part"] == "word/document.xml")
        self.assertEqual(body[1]["paragraph"], [
            {"text": "Keep ", "revision": None}, {"text": "delete ", "revision": "del"},
            {"text": "accepted ", "revision": "ins"}, {"text": "insert.", "revision": None},
        ])
        self.assertTrue(any("table" in block for block in body))
        self.assertTrue(any(part["part"].startswith("word/header") for part in word["parts"]))
        self.invoke("text", "sample.pptx", "presentation-text.json")
        slides = json.loads((self.root / "presentation-text.json").read_text(encoding="utf-8"))["slides"]
        self.assertEqual(len(slides), 3)
        self.assertIn("第一页 First slide", slides[0]["paragraphs"])
        self.assertIn("第二页 Second slide", slides[1]["paragraphs"])
        self.assertTrue(slides[2]["hidden"])

    def hold_real_tree(self, process):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            tree = process_tree(process.pid)
            if any(name.lower() == "soffice.bin" for name in tree.values()):
                handles = {}
                for pid, name in tree.items():
                    handle = kernel.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
                    if handle:
                        handles[name.lower()] = handle
                        self.addCleanup(kernel.CloseHandle, handle)
                self.assertIn("soffice.bin", handles)
                self.assertIn("python.exe", handles)
                return handles
            self.assertIsNone(process.poll(), "Real Office operation ended before process observation")
            time.sleep(0.01)
        self.fail("Real LibreOffice process was not observed")

    def stop_process(self, process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def tree_failure(self, name, mode):
        output = self.root / name
        options = ["--timeout", "6"] if mode == "timeout" else []
        process = subprocess.Popen([str(self.exe), "render", str(self.root / "long.docx"),
                                    str(output), *options], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_process, process)
        handles = self.hold_real_tree(process)
        if mode == "entry":
            process.kill()
        elif mode == "python":
            self.assertTrue(kernel.TerminateProcess(handles["python.exe"], 1))
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        for handle in handles.values():
            self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0)
        self.assertFalse(output.exists())

    def test_real_engine_tree_exits_when_entry_is_killed(self):
        self.tree_failure("entry-killed", "entry")

    def test_real_engine_tree_exits_when_controller_is_killed(self):
        self.tree_failure("controller-killed", "python")

    def test_real_engine_deadline_is_failure_and_leaves_no_published_pages(self):
        self.tree_failure("deadline", "timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
