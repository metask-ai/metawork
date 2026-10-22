"""Private Windows Office component controller, invoked by bin/office.exe only.

The native entry joins a lifetime Job before starting this controller. Its owner
is the entry for Shell calls, or Application for hosted preview/selftest calls.
A bounded watchdog ends this controller on a blocked UNO call; the owner then
terminates the tree and verifies physical quiet before returning.
No system Office, user Python or user profile is selected by this executable.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "engine/program"
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "python-packages"), str(PROGRAM)]
sys.dont_write_bytecode = True

from office_archive import checked_copy
from defusedxml import ElementTree as ET

INPUT_BYTES = 100 * 1024 * 1024
OUTPUT_BYTES = 256 * 1024 * 1024
MAX_PAGES = 200
MAX_PAGE_PIXELS = 4_000_000
WORD_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
REVISION_ELEMENTS = {WORD_NS + name for name in (
    "ins", "del", "moveFrom", "moveTo", "moveFromRangeStart", "moveFromRangeEnd",
    "moveToRangeStart", "moveToRangeEnd", "rPrChange", "pPrChange", "sectPrChange",
    "tblPrChange", "tblGridChange", "trPrChange", "tcPrChange", "numberingChange",
    "cellIns", "cellDel", "cellMerge",
)}
FILTERS = {".docx": "Office Open XML Text", ".xlsx": "Calc MS Excel 2007 XML",
           ".pptx": "Impress MS PowerPoint 2007 XML", ".pdf": "draw_pdf_import"}
PDF_FILTERS = {".docx": "writer_pdf_Export", ".xlsx": "calc_pdf_Export",
               ".pptx": "impress_pdf_Export"}


def identity(path):
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_size > INPUT_BYTES:
        raise ValueError("Source must be a regular file within the input budget")
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


@contextmanager
def checked_input(source):
    if source.suffix.lower() not in FILTERS:
        raise ValueError("Supported inputs are DOCX, XLSX, PPTX and PDF")
    before = identity(source)
    if source.suffix.lower() != ".pdf":
        with checked_copy(source) as path:
            with zipfile.ZipFile(path) as archive:
                if any(name.lower().endswith("vbaproject.bin") for name in archive.namelist()):
                    raise ValueError("Document macros are outside the Office component scope")
            yield path, before
    else:
        with tempfile.TemporaryDirectory(prefix="metawork-pdf-input-") as directory:
            path = Path(directory) / "input.pdf"
            with source.open("rb") as input_file, path.open("xb") as output:
                opened = os.fstat(input_file.fileno())
                # Windows fstat/lstat ctime precision can differ. Compare the
                # same stable handle fields as the bounded ZIP reader.
                if (opened.st_dev, opened.st_ino, opened.st_size,
                        opened.st_mtime_ns) != before[:4]:
                    raise ValueError("PDF input changed before reading")
                total = 0
                while chunk := input_file.read(65536):
                    total += len(chunk)
                    if total > INPUT_BYTES:
                        raise ValueError("PDF input byte budget exceeded")
                    output.write(chunk)
            with path.open("rb") as stream:
                if stream.read(5) != b"%PDF-":
                    raise ValueError("Input is not a PDF")
            yield path, before


def bounded_file(path, remaining=OUTPUT_BYTES):
    size = path.stat().st_size
    if size <= 0 or size > remaining:
        raise ValueError("Missing or oversized Office result")
    return size


@contextmanager
def operation_scratch(parent):
    with tempfile.TemporaryDirectory(prefix=".metawork-office-", dir=parent) as directory:
        scratch = Path(directory).resolve()
        previous = tempfile.tempdir
        # On hard kill, only this recognizable staging root can remain.
        tempfile.tempdir = str(scratch)
        try:
            yield scratch
        finally:
            tempfile.tempdir = previous


def revisions_remaining(path):
    # Every Word XML part matters, including headers, notes and table properties.
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.startswith("word/") and name.endswith(".xml"):
                root = ET.fromstring(archive.read(name))
                if any(element.tag in REVISION_ELEMENTS for element in root.iter()):
                    return True
    return False


class Engine:
    def __init__(self, directory):
        self.directory = directory
        self.documents = []
        self.desktop = None
        self.process = None

    def __enter__(self):
        profile = (self.directory / "profile").as_uri()
        shared_cache = self.directory / "shared-packages"
        shared_cache.mkdir()
        pipe = "metawork-office-" + uuid.uuid4().hex
        os.environ["URE_BOOTSTRAP"] = (PROGRAM / "fundamental.ini").as_uri()
        os.environ["UserInstallation"] = profile
        import uno
        import unohelper
        from com.sun.star.task import XInteractionHandler

        class AbortInteraction(unohelper.Base, XInteractionHandler):
            def handle(self, request):
                for continuation in request.getContinuations():
                    abort = continuation.queryInterface(
                        uno.getTypeByName("com.sun.star.task.XInteractionAbort"))
                    if abort is not None:
                        abort.select()
                        return

        self.uno = uno
        self.interaction = AbortInteraction()
        environment = dict(os.environ)
        environment.update(PYTHONDONTWRITEBYTECODE="1", SAL_DISABLE_OPENCL="1")
        environment.pop("SC_FORCE_CALCULATION", None)
        # LibreOffice's shared-package writability probe and OpenCL test can
        # transiently write into a writable installation. Keep package caches
        # in this operation and use deterministic CPU calculation. See the
        # pinned engine's dp_manager.cxx and desktop/source/app/opencl.cxx.
        self.process = subprocess.Popen([
            str(PROGRAM / "soffice.com"), f"-env:UserInstallation={profile}",
            f"-env:UNO_SHARED_PACKAGES_CACHE={shared_cache.as_uri()}",
            "--headless", "--norestore", "--nodefault", "--nofirststartwizard",
            f"--accept=pipe,name={pipe};urp;StarOffice.ServiceManager",
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW,
            env=environment)
        local = uno.getComponentContext()
        resolver = local.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", local)
        deadline = time.monotonic() + 15
        while True:
            try:
                self.context = resolver.resolve(f"uno:pipe,name={pipe};urp;StarOffice.ComponentContext")
                break
            except Exception:
                if self.process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Office engine did not become ready") from None
                time.sleep(0.05)
        self.desktop = self.service("com.sun.star.frame.Desktop")
        return self

    def service(self, name):
        return self.context.ServiceManager.createInstanceWithContext(name, self.context)

    @staticmethod
    def properties(**values):
        from com.sun.star.beans import PropertyValue
        result = []
        for name, value in values.items():
            prop = PropertyValue()
            prop.Name, prop.Value = name, value
            result.append(prop)
        return tuple(result)

    def load(self, path):
        from com.sun.star.document.MacroExecMode import NEVER_EXECUTE
        from com.sun.star.document.UpdateDocMode import NO_UPDATE
        document = self.desktop.loadComponentFromURL(path.as_uri(), "_blank", 0,
            self.properties(Hidden=True, ReadOnly=False, MacroExecutionMode=NEVER_EXECUTE,
                            UpdateDocMode=NO_UPDATE, InteractionHandler=self.interaction,
                            PickListEntry=False, FilterName=FILTERS[path.suffix.lower()]))
        if document is None:
            raise RuntimeError("Office engine could not open the document")
        self.documents.append(document)
        return document

    def save(self, document, path, filter_name, **options):
        document.storeToURL(path.as_uri(), self.properties(FilterName=filter_name,
                            Overwrite=False, InteractionHandler=self.interaction, **options))
        bounded_file(path)

    def pdf(self, document, path, suffix):
        options = {}
        if suffix == ".pptx":
            options["FilterData"] = self.uno.Any("[]com.sun.star.beans.PropertyValue",
                                               self.properties(ExportHiddenSlides=True))
        self.save(document, path, PDF_FILTERS[suffix], **options)

    def __exit__(self, kind, value, traceback):
        # If shutdown blocks, the command watchdog and native job remain armed.
        try:
            for document in reversed(self.documents):
                document.close(True)
            if self.desktop is not None and not self.desktop.terminate():
                raise RuntimeError("Office engine refused shutdown")
        finally:
            if self.process is not None:
                try:
                    code = self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    raise RuntimeError("Office engine did not settle") from None
                if code != 0:
                    raise RuntimeError("Office engine exited unsuccessfully")


def convert(engine, source, staged, command, expected_formulas=None):
    document = engine.load(source)
    if command == "accept":
        if source.suffix.lower() != ".docx":
            raise ValueError("Accept requires a DOCX document")
        before = document.getRedlines().getCount()
        engine.service("com.sun.star.frame.DispatchHelper").executeDispatch(
            document.CurrentController.Frame, ".uno:AcceptAllTrackedChanges", "", 0, ())
        if document.getRedlines().getCount() != 0:
            raise RuntimeError("Tracked changes remain after acceptance")
        engine.save(document, staged, FILTERS[".docx"])
        with checked_copy(staged) as result:
            if revisions_remaining(result):
                raise RuntimeError("Saved Word XML still contains tracked changes")
        return {"accepted_revisions": before}
    if command == "recalc":
        if source.suffix.lower() != ".xlsx":
            raise ValueError("Recalc requires an XLSX workbook")
        from spreadsheet_checks import _formulas, _check_formula_caches, _summary
        document.calculateAll()
        engine.save(document, staged, FILTERS[".xlsx"])
        with checked_copy(staged) as result:
            if _formulas(result) != expected_formulas:
                raise ValueError("Recalculation changed or removed workbook formulas")
            _check_formula_caches(result)
            return _summary(result, len(expected_formulas))
    if command == "pdf":
        if source.suffix.lower() not in PDF_FILTERS:
            raise ValueError("PDF export requires DOCX, XLSX or PPTX")
        engine.pdf(document, staged, source.suffix.lower())
        return {}
    raise ValueError("Unknown conversion command")


def render(engine, source, output, width):
    document = engine.load(source)
    expected_slides = document.DrawPages.Count if source.suffix.lower() == ".pptx" else None
    if source.suffix.lower() != ".pdf":
        pdf = engine.directory / "preview.pdf"
        engine.pdf(document, pdf, source.suffix.lower())
        document = engine.load(pdf)
    count = document.DrawPages.Count
    if count < 1 or count > MAX_PAGES:
        raise ValueError("Document page budget exceeded")
    if expected_slides is not None and count != expected_slides:
        raise ValueError("Presentation rendering lost slide pages")
    remaining = OUTPUT_BYTES
    pages = []
    for index in range(count):
        page = document.DrawPages.getByIndex(index)
        height = math.ceil(width * page.Height / page.Width)
        if height < 1 or width * height > MAX_PAGE_PIXELS:
            raise ValueError("Rendered page pixel budget exceeded")
        filename = f"page-{index + 1:04}.png"
        path = output / filename
        exporter = engine.service("com.sun.star.drawing.GraphicExportFilter")
        exporter.setSourceDocument(page)
        if not exporter.filter(engine.properties(URL=path.as_uri(), MediaType="image/png",
                FilterData=engine.uno.Any("[]com.sun.star.beans.PropertyValue",
                                         engine.properties(PixelWidth=width, PixelHeight=height)))):
            raise RuntimeError("Office page export failed")
        remaining -= bounded_file(path, remaining)
        pages.append({"file": filename, "width": width, "height": height,
                      "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    manifest = {"schema": 1, "pages": pages}
    (output / "pages.json").write_text(json.dumps(manifest), encoding="utf-8")
    return {"page_count": count}


def run(args):
    source = Path(args.input).absolute()
    output = Path(args.output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Office output must not already exist")
    if not output.parent.is_dir():
        raise ValueError("Office output parent must already exist")
    expected = {"accept": ".docx", "recalc": ".xlsx", "pdf": ".pdf", "text": ".json"}
    if args.command in expected and output.suffix.lower() != expected[args.command]:
        raise ValueError("Office output extension does not match the operation")
    if args.command in ("accept", "recalc") and source.suffix.lower() != expected[args.command]:
        raise ValueError("Office input extension does not match the operation")
    # Staging is on the destination volume; nothing is published until engine
    # shutdown and content checks finish. A failed attempt owns this whole tree.
    with operation_scratch(output.parent) as scratch:
        staged = scratch / ("result" + output.suffix if args.command != "render" else "pages")
        with checked_input(source) as (input_copy, before):
            expected_formulas = None
            if args.command == "recalc":
                from spreadsheet_checks import _formulas
                expected_formulas = _formulas(input_copy)
            if args.command == "text":
                from document_text import extract
                details = extract(input_copy, staged)
            else:
                with Engine(scratch) as engine:
                    if args.command == "render":
                        staged.mkdir()
                        details = render(engine, input_copy, staged, args.width)
                    else:
                        details = convert(engine, input_copy, staged, args.command, expected_formulas)
            if identity(source) != before:
                raise ValueError("Source changed during Office processing; result not published")
            # Windows rename refuses an existing destination, including a race.
            staged.rename(output)
    return {"status": "success", **details}


def node_environment():
    environment = dict(os.environ)
    environment.pop("NODE_OPTIONS", None)
    environment.pop("NODE_PATH", None)
    return environment


def author(command, arguments):
    if not arguments:
        raise ValueError("Office authoring requires a script path")
    if command == "node":
        return subprocess.run([str(ROOT / "node/node.exe"), "--import",
                               (ROOT / "tools/node.mjs").as_uri(), *arguments],
                              env=node_environment()).returncode
    if arguments[0] == "-c":
        if len(arguments) < 2:
            raise ValueError("Office Python -c requires source text")
        sys.argv = ["-c", *arguments[2:]]
        exec(compile(arguments[1], "<Office Python>", "exec"), {"__name__": "__main__"})
        return 0
    script = Path(arguments[0]).resolve(strict=True)
    if not script.is_file():
        raise ValueError("Office Python requires a regular script")
    sys.argv = [str(script), *arguments[1:]]
    # Packaged dependencies precede script-local imports. This doesn't change
    # any Task-wide environment or the behavior of user/custom Skills.
    sys.path.append(str(script.parent))
    runpy.run_path(str(script), run_name="__main__")
    return 0


def selftest():
    import openpyxl
    import lxml.etree
    import pandas
    import PIL
    with tempfile.TemporaryDirectory(prefix="metawork-office-selftest-") as directory:
        root = Path(directory).resolve()
        with Engine(root) as engine:
            device = engine.service("com.sun.star.awt.Toolkit").createScreenCompatibleDevice(1, 1)
            if not any(font.Name == "Noto Sans CJK SC" for font in device.getFontDescriptors()):
                raise RuntimeError("Bundled Chinese font is not visible to the Office engine")
            document = engine.desktop.loadComponentFromURL("private:factory/swriter", "_blank", 0,
                                                          engine.properties(Hidden=True))
            engine.documents.append(document)
            document.Text.String = "MetaWork Office 中文自检"
            cursor = document.Text.createTextCursor()
            cursor.gotoStart(False)
            cursor.gotoEnd(True)
            cursor.CharFontName = "Noto Sans CJK SC"
            engine.save(document, root / "selftest.pdf", "writer_pdf_Export")
            pages = root / "pages"
            pages.mkdir()
            if render(engine, root / "selftest.pdf", pages, 640)["page_count"] != 1:
                raise RuntimeError("Office self-test pagination failed")
        result = subprocess.run([str(ROOT / "node/node.exe"), "--import", (ROOT / "tools/node.mjs").as_uri(),
            "-e", "require('docx');require('pptxgenjs');process.stdout.write(process.versions.node)"],
            env=node_environment(), capture_output=True, text=True, timeout=15)
        if result.returncode != 0 or result.stderr:
            raise RuntimeError("Packaged authoring libraries are unavailable")
        return {"status": "success", "schema": 1, "python": sys.version.split()[0],
                "node": result.stdout, "font": "Noto Sans CJK SC"}


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("python", "node"):
        watchdog = threading.Timer(300, lambda: os._exit(124))
        watchdog.daemon = True
        watchdog.start()
        try:
            return author(sys.argv[1], sys.argv[2:])
        finally:
            watchdog.cancel()
    parser = argparse.ArgumentParser(description="MetaWork Office component")
    parser.add_argument("command", choices=("accept", "recalc", "pdf", "render", "text", "selftest"))
    parser.add_argument("input", nargs="?")
    parser.add_argument("output", nargs="?")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--width", type=int, default=1280)
    args = parser.parse_args()
    if args.command != "selftest" and (args.input is None or args.output is None):
        parser.error("An input and a new output path are required")
    if args.command == "selftest" and (args.input is not None or args.output is not None):
        parser.error("Self-test takes no document paths")
    if os.name != "nt" or not 0 < args.timeout <= 300 or not 128 <= args.width <= 2048:
        parser.error("Windows required; timeout must be (0, 300], width must be [128, 2048]")
    watchdog = threading.Timer(args.timeout, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    try:
        result = selftest() if args.command == "selftest" else run(args)
        print(json.dumps(result, ensure_ascii=True), flush=True)
        return 0 if result["status"] == "success" else 1
    except Exception:
        # UNO exceptions may contain raw document paths or remote URLs.
        print(json.dumps({"status": "failed", "error": "Office operation failed; no result published"}), flush=True)
        return 1
    finally:
        watchdog.cancel()


if __name__ == "__main__":
    raise SystemExit(main())
