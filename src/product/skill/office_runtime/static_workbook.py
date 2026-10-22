"""Freeze saved XLSX values in a private rendering copy, without calculation.

Never-recalculate-on-load still evaluates missing/volatile cells in the pinned
engine. Only this checked copy enters Calc for layout. The original grid and
formula inspection continue to use the unchanged source. Unsupported active
objects fail before document loading; this is not a general XLSX sanitizer.
"""
import math
import re
import zipfile

from lxml import etree

S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
C = "http://schemas.openxmlformats.org/drawingml/2006/chart"
XML_BYTES = 16 * 1024 * 1024
TOTAL_XML_BYTES = 64 * 1024 * 1024
MAX_CELLS = 100_000
MAX_ROWS = 10_000
MAX_COLUMNS = 256
FORBIDDEN_PARTS = ("xl/externallinks/", "xl/querytables/", "xl/pivot", "xl/embeddings/",
                   "xl/ctrlprops/", "xl/macrosheets/", "xl/dialogsheets/")
RELATIONSHIPS = {
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/" + name
    for name in ("officeDocument", "worksheet", "chartsheet", "styles", "sharedStrings", "theme",
                 "drawing", "chart", "image", "table", "calcChain", "comments", "hyperlink",
                 "extended-properties", "custom-properties")
} | {
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties",
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail",
    "http://schemas.microsoft.com/office/2011/relationships/chartStyle",
    "http://schemas.microsoft.com/office/2011/relationships/chartColorStyle",
}
IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp")


def column(value):
    result = 0
    for character in value:
        result = result * 26 + ord(character) - 64
    return result


def address(value):
    match = re.fullmatch(r"\$?([A-Z]{1,3})\$?([1-9][0-9]{0,4})", value)
    return bool(match and column(match[1]) <= MAX_COLUMNS and int(match[2]) <= MAX_ROWS)


def literal_ranges(value, sheets):
    # A1/column/row unions only. No names, expressions, external workbooks,
    # functions or structured references can become executable chart/name data.
    part = r"(?:'((?:[^']|'')+)'|([^'!,]+))!([^,]+)"
    offset = 0
    while offset < len(value):
        match = re.match(part, value[offset:])
        if not match:
            return False
        name = match[1].replace("''", "'") if match[1] is not None else match[2]
        if name not in sheets:
            return False
        if match[1] is None and (not (name[0].isalpha() or name[0] == "_")
                                or any(not (character.isalnum() or character in "_.") for character in name)):
            return False
        ends = match[3].split(":")
        if not 1 <= len(ends) <= 2:
            return False
        kinds = []
        for end in ends:
            if address(end):
                kinds.append("cell")
                continue
            row = re.fullmatch(r"\$?([1-9][0-9]{0,4})", end)
            col = re.fullmatch(r"\$?([A-Z]{1,3})", end)
            if len(ends) != 2 or not ((row and int(row[1]) <= MAX_ROWS)
                                     or (col and column(col[1]) <= MAX_COLUMNS)):
                return False
            kinds.append("row" if row else "column")
        if len(set(kinds)) != 1:
            return False
        offset += match.end()
        if offset == len(value):
            return True
        if value[offset] != ",":
            return False
        offset += 1
        if offset == len(value):
            return False
    return False


def parse(data):
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False,
                             recover=False, huge_tree=False)
    root = etree.fromstring(data, parser)
    if root.getroottree().docinfo.doctype:
        raise ValueError("Workbook layout does not accept a DTD")
    return root


def freeze_cell(node, report):
    formulas = node.findall(f"{{{S}}}f")
    if len(formulas) > 1:
        raise ValueError("Workbook layout formula representation is invalid")
    if formulas:
        node.remove(formulas[0])
        report["formula_cells"] += 1
    value = node.find(f"{{{S}}}v")
    kind = node.get("t", "n")
    if formulas and (value is None or value.text is None):
        report["missing_formula_caches"] += 1
        if value is not None:
            node.remove(value)
        node.attrib.pop("t", None)
        return True
    if kind in ("str", "b", "e"):
        if value is None or value.text is None:
            raise ValueError("Workbook layout literal value is missing")
        text_value = value.text
        if kind == "b":
            if text_value not in ("0", "1"):
                raise ValueError("Workbook layout boolean cache is invalid")
            text_value = "TRUE" if text_value == "1" else "FALSE"
        # Calc imports booleans/errors as implicit formulas. Use their literal
        # displayed text in this rendering-only copy, retaining styles. The
        # original grid remains typed and keeps the original formula/value.
        node.remove(value)
        node.set("t", "inlineStr")
        text = etree.SubElement(etree.SubElement(node, f"{{{S}}}is"), f"{{{S}}}t")
        text.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        text.text = text_value
        return True
    if formulas:
        if kind == "n":
            if not math.isfinite(float(value.text)):
                raise ValueError("Workbook layout cache is not finite")
        elif kind not in ("s", "d"):
            raise ValueError("Workbook layout cache type is unsupported")
    return bool(formulas)


def freeze(source, destination):
    # The caller owns a canonical checked_copy and private destination. Bounded
    # source_text also checks all relationships, active content and XML first.
    from document_preview import source_text
    _, source_omissions = source_text(source)
    report = {"saved_values_only": True, "formula_cells": 0,
              "missing_formula_caches": 0, "removed_defined_names": 0,
              "omissions": []}
    omissions = {item for item in source_omissions if item == "external_hyperlinks"}
    with zipfile.ZipFile(source) as original:
        members = original.infolist()
        xml_bytes = 0
        for item in members:
            if item.is_dir():
                continue
            lower = item.filename.lower()
            if (lower.startswith(FORBIDDEN_PARTS) or lower in ("xl/connections.xml", "xl/metadata.xml")
                    or lower.endswith(".vml")):
                raise ValueError("Workbook layout contains an unsupported active object")
            if lower.endswith((".xml", ".rels")):
                xml_bytes += item.file_size
                if item.file_size > XML_BYTES or xml_bytes > TOTAL_XML_BYTES:
                    raise ValueError("Workbook layout XML budget exceeded")
            elif lower.endswith(IMAGE_EXTENSIONS):
                from PIL import Image
                with original.open(item) as stream, Image.open(stream) as image:
                    if (image.format not in ("PNG", "JPEG", "GIF", "BMP", "TIFF", "WEBP")
                            or image.width * image.height > 16_777_216):
                        raise ValueError("Workbook layout image budget exceeded")
                    image.verify()
            else:
                raise ValueError("Workbook layout contains an unsupported binary resource")
        workbook = parse(original.read("xl/workbook.xml"))
        sheets = {node.get("name") for node in workbook.iter(f"{{{S}}}sheet")}
        if not sheets or None in sheets or len(sheets) > 64:
            raise ValueError("Workbook layout sheet budget exceeded")
        visited = 0
        with zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED) as output:
            for item in members:
                data = original.read(item)
                if item.filename.lower().endswith((".xml", ".rels")):
                    root = parse(data)
                    changed = False
                    for node in list(root.iter()):
                        if not isinstance(node.tag, str) or node.getparent() is None:
                            continue
                        if not any(parent is root for parent in node.iterancestors()):
                            continue
                        name = etree.QName(node)
                        if name.localname in ("externalData", "externalLink", "externalReference", "externalReferences",
                                              "connection", "queryTable", "oleObject", "control", "ddeLink", "oleLink"):
                            raise ValueError("Workbook layout contains an unsupported active object")
                        if name.localname == "Relationship" and node.get("Type") not in RELATIONSHIPS:
                            raise ValueError("Workbook layout relationship type is unsupported")
                        if name.localname == "Relationship" and node.get("TargetMode", "").lower() == "external":
                            node.getparent().remove(node)
                            changed = True
                        elif name.localname in ("hyperlink", "hlinkClick", "hlinkHover"):
                            node.getparent().remove(node)
                            changed = True
                        elif (name.namespace == S and name.localname == "extLst"
                                or name.localname == "AlternateContent"):
                            raise ValueError("Workbook layout does not support calculation extensions")
                        if node.tag in (f"{{{S}}}conditionalFormatting", f"{{{S}}}dataValidations"):
                            omissions.add("conditional_formatting" if name.localname == "conditionalFormatting"
                                          else "data_validation")
                            node.getparent().remove(node)
                            changed = True
                        elif node.tag == f"{{{S}}}definedName":
                            if not literal_ranges(node.text or "", sheets):
                                if node.get("name", "").startswith("_xlnm.Print_"):
                                    raise ValueError("Workbook layout print range is unsupported")
                                node.getparent().remove(node)
                                report["removed_defined_names"] += 1
                                changed = True
                        elif node.tag == f"{{{S}}}c":
                            visited += 1
                            if visited > MAX_CELLS or not address(node.get("r", "")):
                                raise ValueError("Workbook layout cell/extent budget exceeded")
                            changed = freeze_cell(node, report) or changed
                        elif node.tag in (f"{{{S}}}calculatedColumnFormula", f"{{{S}}}totalsRowFormula"):
                            node.getparent().remove(node)
                            changed = True
                        elif node.tag == f"{{{S}}}tableColumn" and "totalsRowFunction" in node.attrib:
                            node.set("totalsRowFunction", "none")
                            changed = True
                        elif node.tag == f"{{{S}}}calcPr":
                            node.attrib.update({"calcMode": "manual", "fullCalcOnLoad": "0",
                                                "forceFullCalc": "0", "calcOnSave": "0"})
                            changed = True
                        elif node.tag == f"{{{C}}}f":
                            if not literal_ranges(node.text or "", sheets):
                                raise ValueError("Workbook layout chart reference is unsupported")
                        elif (name.localname in ("f", "formula", "formula1", "formula2")
                              and node.getparent() is not None):
                            raise ValueError("Workbook layout contains an unsupported formula")
                    if changed:
                        data = etree.tostring(root, xml_declaration=True, encoding="utf-8")
                        if len(data) > XML_BYTES:
                            raise ValueError("Workbook layout transformed XML budget exceeded")
                output.writestr(item, data)
    report["omissions"] = sorted(omissions)
    return report
