"""Bounded, non-OCR PDF inspection before the existing engine may load it.

The scope is reachable PDF string/name values, XMP text/attributes, and decoded
page text including invisible/out-of-page text. It is not an OCR or arbitrary
font-glyph guarantee. Unknown font mappings and parser recovery are rejected.
"""
import logging
from xml.sax.handler import ContentHandler

from defusedxml import sax
from pypdf import PdfReader, apply_configuration
from pypdf.generic import (
    ArrayObject, ByteStringObject, DictionaryObject, IndirectObject,
    NameObject, StreamObject, TextStringObject,
)

MAX_OBJECTS = 50_000
MAX_DEPTH = 64
MAX_STREAM = 4 * 1024 * 1024
MAX_DECODED = 16 * 1024 * 1024
MAX_IMAGE_PIXELS = 32_000_000
SCOPE = "pdf_reachable_strings_xmp_and_decoded_page_text_without_ocr"


class ParserWarnings(logging.Handler):
    def __init__(self):
        super().__init__(logging.WARNING)
        self.seen = False

    def emit(self, record):
        # Parser messages can contain input strings. Never format or retain them.
        self.seen = True


class Scan:
    def __init__(self, maximum):
        self.maximum = maximum
        self.text = bytearray()
        self.compact = bytearray()
        self.visited = set()
        self.count = 0
        self.decoded = 0
        self.image_pixels = 0
        self.omissions = set()

    def append(self, value, compact=False):
        if len(value) > self.maximum:
            raise ValueError("PDF inspection text exceeds budget")
        encoded = value.encode("utf-8", errors="strict")
        joined = "".join(value.split()).encode("utf-8") if compact else b""
        if len(self.text) + len(self.compact) + len(encoded) + len(joined) + 1 > self.maximum:
            raise ValueError("PDF inspection text exceeds budget")
        self.text.extend(encoded)
        self.compact.extend(joined)

    def decoded_stream(self, value):
        data = value.get_data()
        self.decoded += len(data)
        if len(data) > MAX_STREAM or self.decoded > MAX_DECODED:
            raise ValueError("PDF decoded streams exceed budget")
        return data

    def visit(self, value, depth=0, as_action=False):
        if depth > MAX_DEPTH:
            raise ValueError("PDF object depth exceeds budget")
        if isinstance(value, IndirectObject):
            identity = (value.idnum, value.generation, as_action)
            if identity in self.visited:
                return
            self.visited.add(identity)
            value = value.get_object()
        self.count += 1
        if self.count > MAX_OBJECTS:
            raise ValueError("PDF object count exceeds budget")
        if isinstance(value, NameObject):
            self.append(str(value))
        elif isinstance(value, TextStringObject):
            self.append(str(value))
        elif isinstance(value, ByteStringObject):
            # Preserve ASCII in non-text byte strings; encoded glyph text is
            # inspected separately using the actual page font mapping.
            self.append(bytes(value).decode("latin-1"))
        elif isinstance(value, ArrayObject):
            for item in value:
                self.visit(item, depth + 1, as_action)
        elif isinstance(value, DictionaryObject):
            kind = value.get("/Type")
            subtype = value.get("/Subtype")
            if kind in ("/Filespec", "/EmbeddedFile") or subtype in ("/Type3", "/RichMedia", "/Movie", "/Sound", "/Screen", "/Widget"):
                raise ValueError("PDF contains unsupported embedded or interactive content")
            for name in ("/JS", "/JavaScript", "/AA", "/AcroForm", "/XFA", "/EmbeddedFiles", "/EF", "/Collection", "/OCProperties", "/AP"):
                if name in value:
                    raise ValueError("PDF contains unsupported active or uninspectable content")
            if value.get("/Pattern"):
                raise ValueError("PDF pattern text inspection is unsupported")
            if "/OpenAction" in value and not isinstance(value["/OpenAction"], ArrayObject):
                raise ValueError("PDF contains an executable open action")
            action = value.get("/S")
            if (as_action or kind == "/Action") and action not in ("/URI", "/GoTo"):
                raise ValueError("PDF contains an unsupported action")
            if "/JS" in value or action in ("/JavaScript", "/Launch", "/GoToR", "/GoToE", "/SubmitForm", "/ImportData", "/Rendition"):
                raise ValueError("PDF contains an external or executable action")
            if action == "/URI":
                self.omissions.add("external_hyperlinks")
            if subtype == "/Image":
                width, height = value.get("/Width"), value.get("/Height")
                if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
                    raise ValueError("PDF image dimensions are invalid")
                self.image_pixels += width * height
                if width * height > 16_777_216 or self.image_pixels > MAX_IMAGE_PIXELS:
                    raise ValueError("PDF images exceed pixel budget")
            if kind == "/Font":
                if subtype not in ("/Type0", "/Type1", "/TrueType", "/CIDFontType0", "/CIDFontType2"):
                    raise ValueError("PDF font mapping is unsupported")
                if subtype == "/Type0" and "/ToUnicode" not in value:
                    raise ValueError("PDF composite font has no Unicode mapping")
                encoding = value.get("/Encoding")
                if subtype in ("/Type1", "/TrueType") and "/ToUnicode" not in value and encoding not in (None, "/WinAnsiEncoding", "/MacRomanEncoding", "/StandardEncoding"):
                    raise ValueError("PDF font has no verified text mapping")
            if isinstance(value, StreamObject):
                # F/FFilter are file-backed stream sources, never local grants.
                if "/F" in value or "/FFilter" in value or "/FDecodeParms" in value:
                    raise ValueError("PDF stream references an external file")
                if kind == "/Metadata":
                    if subtype != "/XML":
                        raise ValueError("PDF metadata format is unsupported")
                    sax.parseString(self.decoded_stream(value), XmpText(self))
                elif subtype != "/Image":
                    self.decoded_stream(value)
            for name, item in value.items():
                self.visit(name, depth + 1)
                self.visit(item, depth + 1, (name == "/A" and kind != "/StructElem") or (name == "/Next" and (as_action or kind == "/Action")))


class XmpText(ContentHandler):
    def __init__(self, scan):
        super().__init__()
        self.scan = scan
        self.depth = 0
        self.elements = 0

    def startElement(self, name, attrs):
        self.depth += 1
        self.elements += 1
        if self.depth > MAX_DEPTH or self.elements > MAX_OBJECTS:
            raise ValueError("PDF metadata complexity exceeds budget")
        for value in attrs.values():
            self.scan.append(value)

    def endElement(self, name):
        self.depth -= 1

    def characters(self, value):
        # Keep a text-only stream as well: XML attributes between adjacent
        # text nodes must not split a credential in the metadata body.
        self.scan.append(value, compact=True)


def extract(source, maximum):
    warnings = ParserWarnings()
    logger = logging.getLogger("pypdf")
    previous = logger.handlers[:], logger.level, logger.propagate
    logger.handlers = [warnings]
    logger.setLevel(logging.WARNING)
    logger.propagate = False
    try:
        with apply_configuration(
                # Text inspection must never discover or invoke a second executable.
                jbig2dec_binary=None,
                jbig2_maximum_output_length=MAX_STREAM,
                image_maximum_buffer_size=MAX_STREAM,
                maximum_declared_stream_length=16 * 1024 * 1024,
                array_based_stream_maximum_output_length=MAX_STREAM,
                array_maximum_element_count=MAX_OBJECTS,
                dictionary_maximum_element_count=MAX_OBJECTS,
                lzw_maximum_output_length=MAX_STREAM,
                run_length_maximum_output_length=MAX_STREAM,
                zlib_maximum_output_length=MAX_STREAM,
                zlib_maximum_recovery_input_length=MAX_STREAM,
                brotli_maximum_output_length=MAX_STREAM,
                stream_filters_maximum_length=4,
                stream_decoding_work_maximum_length=MAX_DECODED,
                stream_parsing_work_maximum_count=250_000,
                page_tree_maximum_entries=200,
                page_tree_maximum_depth=MAX_DEPTH,
                xform_maximum_invocations_per_extraction=100):
            with source.open("rb") as stream:
                reader = PdfReader(stream, strict=True)
                if reader.is_encrypted:
                    raise ValueError("Encrypted PDF preview is unsupported")
                if "/Prev" in reader.trailer:
                    raise ValueError("Incremental PDF inspection is unsupported")
                count = len(reader.pages)
                if count < 1 or count > 100:
                    raise ValueError("PDF page count exceeds budget")
                scan = Scan(maximum)
                scan.visit(reader.trailer)
                for page in reader.pages:
                    def text(value, matrix, text_matrix, font, size):
                        if value:
                            if font is None and value.strip():
                                raise ValueError("PDF page text uses an unknown font")
                            scan.append(value, compact=True)
                    page.extract_text(visitor_text=text)
                if warnings.seen:
                    raise ValueError("PDF text inspection required parser recovery")
                return bytes(scan.text + b"\n" + scan.compact), sorted(scan.omissions), count
    finally:
        logger.handlers, logger.level, logger.propagate = previous
