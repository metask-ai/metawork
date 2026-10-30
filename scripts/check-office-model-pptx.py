"""Independent business oracle for the frozen synthetic PPTX model task.

Run through a prepared private Python entry. Receipt comparison and truthful
final wording are evaluated separately from this content/structure oracle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

from defusedxml import ElementTree as E
from office_archive import checked_copy

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("candidate", type=Path)
parser.add_argument("--entry", required=True, type=Path)
parser.add_argument("--original", type=Path, help="For the frozen title-only follow-up")
args = parser.parse_args()
NS = {"p": "http://schemas.openxmlformats.org/presentationml/2006/main",
      "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
      "c": "http://schemas.openxmlformats.org/drawingml/2006/chart",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
R = "{http://schemas.openxmlformats.org/package/2006/relationships}"


def read(path):
    with checked_copy(path) as frozen, zipfile.ZipFile(frozen) as packed:
        return {name: packed.read(name) for name in packed.namelist() if not name.endswith("/")}


def check(content, edited):
    import posixpath
    def relations(part):
        path = posixpath.join(posixpath.dirname(part), "_rels", posixpath.basename(part) + ".rels")
        return {item.get("Id"): posixpath.normpath(posixpath.join(posixpath.dirname(part), item.get("Target"))).lstrip("/")
                for item in E.fromstring(content[path]) if item.tag == R + "Relationship" and item.get("TargetMode") != "External"}
    presentation = E.fromstring(content["ppt/presentation.xml"])
    rels = relations("ppt/presentation.xml")
    slides = [rels[item.get("{" + NS["r"] + "}id")] for item in presentation.findall("p:sldIdLst/p:sldId", NS)]
    assert len(slides) == 3, "Exactly three ordered slides required"
    titles = ["销售汇总（已复验）" if edited else "销售汇总", "地区金额", "地区趋势"]
    charts = []
    for index, slide in enumerate(slides):
        tree = E.fromstring(content[slide])
        texts = ["".join(item.text or "" for item in paragraph.findall(".//a:t", NS))
                 for paragraph in tree.findall(".//a:p", NS)]
        assert titles[index] in texts, (index, "Title missing")
        if index == 0:
            assert "总额650" in texts, "Exact total text missing"
            note_rels = relations(slide)
            notes = [name for name in note_rels.values() if name.startswith("ppt/notesSlides/")]
            assert len(notes) == 1 and "验收备注：650" in ["".join(item.text or "" for item in paragraph.findall(".//a:t", NS)) for paragraph in E.fromstring(content[notes[0]]).findall(".//a:p", NS)], "Speaker note missing"
        chart_refs = tree.findall(".//c:chart", NS)
        assert len(chart_refs) == (0 if index == 0 else 1), "Native chart count differs"
        if not chart_refs:
            continue
        chart_path = relations(slide)[chart_refs[0].get("{" + NS["r"] + "}id")]
        chart = E.fromstring(content[chart_path]); plot = chart.find("c:chart/c:plotArea", NS)
        kind = "barChart" if index == 1 else "lineChart"
        shape = plot.find("c:" + kind, NS)
        assert shape is not None, "Wrong native chart type"
        series = shape.findall("c:ser", NS)
        assert len(series) == 1, "One Amount series required"
        series = series[0]
        def cache(parent):
            return [item.text for item in parent.findall(".//c:pt/c:v", NS)]
        assert cache(series.find("c:cat", NS)) == ["North", "South"], "Category cache differs"
        assert [float(value) for value in cache(series.find("c:val", NS))] == [300, 350], "Numeric cache differs"
        tx = series.find("c:tx", NS)
        assert tx is not None and "Amount" in [item.text for item in tx.findall(".//c:v", NS)], "Series name differs"
        labels = series.find("c:dLbls", NS)
        if labels is None: labels = shape.find("c:dLbls", NS)
        assert labels is not None and labels.find("c:showVal", NS) is not None and labels.find("c:showVal", NS).get("val") in ("1", "true"), "Numeric data labels missing"
        if index == 1:
            assert shape.find("c:barDir", NS).get("val") == "col", "Expected vertical bars"
            colors = {int(point.find("c:idx", NS).get("val")): point.find("c:spPr/a:solidFill/a:srgbClr", NS).get("val").upper()
                      for point in series.findall("c:dPt", NS)}
            assert colors == {0: "0D9488", 1: "14B8A6"}, "Point colors differ"
        else:
            assert shape.find("c:grouping", NS).get("val") == "standard", "Expected ordinary unstacked line"
            marker = series.find("c:marker/c:symbol", NS)
            assert marker is not None and marker.get("val") != "none", "Visible line markers required"
        charts.append(chart_path)
    return slides, charts


try:
    content = read(args.candidate)
    slides, charts = check(content, args.original is not None)
    if args.original:
        original = read(args.original)
        original_slides, _ = check(original, False)
        assert slides == original_slides and set(content) == set(original), "Package identity changed"
        for name in original:
            if name != slides[0]: assert original[name] == content[name], (name, "Unrelated part changed")
        before, after = E.fromstring(original[slides[0]]), E.fromstring(content[slides[0]])
        def title(tree, text):
            return [paragraph for paragraph in tree.findall(".//a:p", NS)
                    if "".join(item.text or "" for item in paragraph.findall(".//a:t", NS)) == text]
        old_targets, new_targets = title(before, "销售汇总"), title(after, "销售汇总（已复验）")
        assert len(old_targets) == len(new_targets) == 1
        old_runs, new_runs = old_targets[0].findall(".//a:t", NS), new_targets[0].findall(".//a:t", NS)
        assert len(old_runs) == len(new_runs), "Title edit changed run styling structure"
        for old, new in zip(old_runs, new_runs): new.text = old.text
        assert E.tostring(before) == E.tostring(after), "First slide changed beyond its title"
    entry = args.entry.resolve(strict=True)
    command = (["/bin/sh", str(entry)] if entry.suffix == ".sh" else [str(entry)]) + ["python", str(entry.parent.parent / "scripts/office/validate.py"), str(args.candidate)]
    result = subprocess.run(command, text=True, capture_output=True, timeout=90)
    assert result.returncode == 0, "Strict candidate validation failed"
    data = args.candidate.read_bytes()
    print(json.dumps({"status": "passed", "candidate": {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}, "slide_count": len(slides), "native_chart_count": len(charts), "receipt_comparison": "pending", "final_wording_review": "pending"}))
except Exception as error:
    print(json.dumps({"status": "failed", "reason": str(error) if isinstance(error, AssertionError) else type(error).__name__}))
    raise SystemExit(1)
