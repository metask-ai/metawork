"""Finalize a newly authored PPTX work copy, then run the strict validator.

Usage: <run entry> python scripts/finalize.py generated.pptx checked.pptx
       [--line-grouping standard]
Only use immediately after the fixed PptxGenJS authoring step, never on an
existing user presentation. A successful result covers structure, not visuals.
"""
import argparse
from collections import Counter
from contextlib import redirect_stdout
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

from lxml import etree as E
from office_archive import checked_copy, temporary_extract, DEFAULT_LIMITS

sys.path.insert(0, str(Path(__file__).resolve().parent / "office"))
from validators import PPTXSchemaValidator

P = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
C = "{http://schemas.openxmlformats.org/drawingml/2006/chart}"
LIMITS = replace(DEFAULT_LIMITS, archive_bytes=32 * 1024 * 1024,
                 member_bytes=16 * 1024 * 1024, total_bytes=64 * 1024 * 1024)


class Rejected(ValueError):
    """Fixed diagnostics, without document text or third-party exception text."""


class DiscardDiagnostics:
    def write(self, text):
        return len(text)

    def flush(self):
        pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def parse(data):
    tree = E.fromstring(data, E.XMLParser(resolve_entities=False, load_dtd=False,
                                         no_network=True, huge_tree=False))
    require(not tree.getroottree().docinfo.doctype, "DTD is outside the supported input")
    return tree


def one(parent, name, *, required=False):
    found = parent.findall(name)
    require(len(found) <= 1 and (found or not required), "Missing or ambiguous structural element")
    return found[0] if found else None


def numeric_id(value):
    require(isinstance(value, str) and len(value) <= 10 and value.isascii() and value.isdecimal() and int(value) <= 0xffffffff,
            "Unsupported axis or point identifier")
    return int(value)


def simple_id(element):
    require(element is not None and set(element.attrib) == {"val"} and not len(element),
            "Unsupported axis or point identifier")
    return numeric_id(element.get("val"))


def presentation(tree):
    require(tree.tag == P + "presentation", "Unsupported presentation namespace")
    notes, slides = one(tree, P + "notesMasterIdLst"), one(tree, P + "sldIdLst", required=True)
    if notes is not None and tree.index(notes) > tree.index(slides):
        require(tree.index(notes) == tree.index(slides) + 1,
                "Unrecognized notes-list ordering")
        tree.remove(notes)
        tree.insert(tree.index(slides), notes)
        return ["notes_master_before_slide_list"]
    return []


def chart(tree, line_grouping):
    require(tree.tag == C + "chartSpace", "Unsupported chart namespace")
    changes = Counter()
    for plot in tree.iter(C + "plotArea"):
        shapes = [item for item in plot if isinstance(item.tag, str) and
                  item.tag.startswith(C) and item.tag.endswith("Chart")]
        targets = [item for item in shapes if item.tag in (C + "barChart", C + "lineChart")]
        if not targets:
            continue  # Other chart types are unchanged and must pass strict validation.
        require(len(shapes) == len(targets) == 1, "Combined charts are outside the processing scope")
        shape = targets[0]
        axes = [item for item in plot if item.tag in
                (C + "catAx", C + "valAx", C + "dateAx", C + "serAx")]
        require(sorted(item.tag for item in axes) == sorted((C + "catAx", C + "valAx")),
                "Only a single two-dimensional category/value axis pair is supported")
        definitions = [simple_id(one(axis, C + "axId", required=True)) for axis in axes]
        require(len(set(definitions)) == 2, "Duplicate axis definitions")
        for index, axis in enumerate(axes):
            require(simple_id(one(axis, C + "crossAx", required=True)) == definitions[1 - index],
                    "Axis cross-reference does not identify the other defined axis")
        references = shape.findall(C + "axId")
        ids = [simple_id(axis) for axis in references]
        require(len(ids) == len(set(ids)), "Duplicate chart axis references")
        orphan = [axis for axis in references if simple_id(axis) not in definitions]
        if orphan:
            require(len(references) == 3 and len(orphan) == 1 and set(definitions) < set(ids),
                    "Unrecognized undefined-axis pattern")
            unused_id = simple_id(orphan[0])
            require(sum(simple_id(item) == unused_id for item in tree.iter(C + "axId")) == 1,
                    "Undefined axis identifier is used elsewhere")
            shape.remove(orphan[0])
            changes["removed_single_undefined_2d_axis_reference"] += 1
        else:
            require(len(references) == 2 and set(ids) == set(definitions), "Incomplete chart axis references")
        is_line = shape.tag == C + "lineChart"
        if is_line:
            grouping = one(shape, C + "grouping")
            if grouping is None:
                require(line_grouping == "standard", "Line grouping must be explicitly declared standard")
                shape.insert(0, E.Element(C + "grouping", val="standard"))
                changes["inserted_declared_standard_line_grouping"] += 1
            else:
                require(grouping.get("val") == "standard", "Only standard line grouping is qualified")
        for series in shape.findall(C + "ser"):
            labels = one(series, C + "dLbls")
            points = series.findall(C + "dPt")
            point_ids = [simple_id(one(point, C + "idx", required=True)) for point in points]
            require(len(point_ids) == len(set(point_ids)), "Duplicate data-point indices")
            if points:
                sizes = []
                for role in ("cat", "val"):
                    container = one(series, C + role, required=True)
                    caches = [item for item in container.iter() if item.tag in
                              (C + "strCache", C + "numCache", C + "strLit", C + "numLit", C + "multiLvlStrCache")]
                    require(len(caches) == 1, "Single-level cached category/value data is required for point styling")
                    cache = caches[0]
                    size = simple_id(one(cache, C + "ptCount", required=True))
                    # The pinned generator represents a single category level
                    # inside multiLvlStrCache. Do not generalize to hierarchies.
                    point_container = one(cache, C + "lvl", required=True) if cache.tag == C + "multiLvlStrCache" else cache
                    indices = [numeric_id(item.get("idx")) for item in point_container.findall(C + "pt")]
                    require(len(indices) == size and sorted(indices) == list(range(len(indices))),
                            "Incomplete or ambiguous point cache")
                    sizes.append(size)
                require(sizes[0] == sizes[1] and all(index < sizes[0] for index in point_ids),
                        "Styled point does not identify existing category/value data")
            if labels is not None:
                for point in points:
                    if series.index(point) > series.index(labels):
                        # Require exactly the generator's trailing point block;
                        # unknown elements are not sorted into apparent validity.
                        between = list(series)[series.index(labels) + 1:series.index(point)]
                        require(all(item.tag == C + "dPt" for item in between),
                                "Unrecognized series data-point ordering")
                        series.remove(point)
                        series.insert(series.index(labels), point)
                        changes["data_point_before_series_labels"] += 1
            if is_line:
                invert = one(series, C + "invertIfNegative")
                if invert is not None:
                    require(dict(invert.attrib) == {"val": "0"} and not len(invert),
                            "Nontrivial line invertIfNegative is unsupported")
                    series.remove(invert)
                    changes["removed_false_bar_only_line_property"] += 1
                marker = one(series, C + "marker")
                after = [item for item in series if item.tag in (C + "dPt", C + "dLbls")]
                if marker is not None and after and series.index(marker) > series.index(after[0]):
                    between = list(series)[series.index(after[0]):series.index(marker)]
                    require(all(item.tag in (C + "dPt", C + "dLbls") for item in between),
                            "Unrecognized line marker ordering")
                    series.remove(marker)
                    series.insert(series.index(after[0]), marker)
                    changes["marker_before_line_data_points_and_labels"] += 1
    return changes


def finalize(source, output, line_grouping=None):
    require(source.suffix.lower() == output.suffix.lower() == ".pptx", "PPTX paths are required")
    # Exclusive publication itself rejects an existing file, alias or hard link.
    require(not output.exists() and not output.is_symlink(), "Output path must be new")
    with checked_copy(source, LIMITS) as frozen, tempfile.TemporaryDirectory(prefix="metawork-pptx-") as directory:
        with zipfile.ZipFile(frozen) as packed:
            parts = {item.filename: packed.read(item) for item in packed.infolist() if not item.is_dir()}
        require("ppt/presentation.xml" in parts, "Presentation part is missing")
        changes, nodes, changed_parts = Counter(), 0, 0
        for name, data in parts.items():
            if not name.endswith((".xml", ".rels")):
                continue
            tree = parse(data)
            nodes += sum(1 for _ in tree.iter())
            require(nodes <= 600_000, "XML traversal budget exceeded")
            edits = presentation(tree) if name == "ppt/presentation.xml" else chart(tree, line_grouping) if name.startswith("ppt/charts/") and tree.tag == C + "chartSpace" else []
            if edits:
                changes.update(edits)
                changed_parts += 1
                parts[name] = E.tostring(tree, xml_declaration=True, encoding="UTF-8", standalone=True)
        staged = Path(directory) / "checked.pptx"
        with zipfile.ZipFile(staged, "x", zipfile.ZIP_DEFLATED) as packed:
            for name, data in parts.items():
                packed.writestr(name, data)
        with temporary_extract(staged, LIMITS) as extracted, redirect_stdout(DiscardDiagnostics()):
            require(PPTXSchemaValidator(extracted).validate(), "Strict structure validation failed")
        digest = hashlib.sha256(staged.read_bytes()).hexdigest()
        created = False
        try:
            with output.open("xb") as destination, staged.open("rb") as original:
                created = True
                shutil.copyfileobj(original, destination)
        except BaseException:
            if created:
                output.unlink(missing_ok=True)
            raise
        return {"status": "structure_passed", "candidate": {"bytes": staged.stat().st_size, "sha256": digest},
                "changes": dict(changes), "changed_parts": changed_parts,
                "visual_check": "not_performed", "powerpoint_check": "not_performed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--line-grouping", choices=("standard",))
    args = parser.parse_args()
    try:
        print(json.dumps(finalize(args.source, args.output, args.line_grouping), ensure_ascii=True))
    except Rejected as error:
        print(json.dumps({"status": "rejected", "reason": str(error)}))
        return 1
    except Exception as error:
        print(json.dumps({"status": "execution_error", "error_type": type(error).__name__}))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
