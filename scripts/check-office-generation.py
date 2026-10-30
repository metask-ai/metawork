"""Qualify fixed private generators and unmodified strict validators.

Use the current packaged run entry for BOTH this Python process and --node-entry.
A nonzero exit means the generated feature set is not qualified. Diagnostic
copies isolate defects only; they are never production fixes or viewer evidence.
"""
import argparse
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import zipfile

from lxml import etree
import office_qualification as qualification

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--node-entry", required=True, type=Path)
parser.add_argument("--python-entry", required=True, type=Path)
parser.add_argument("--report", required=True, type=Path)
args = parser.parse_args()
node_entry = args.node_entry.resolve(strict=True)
python_entry = args.python_entry.resolve(strict=True)
office = python_entry.parent.parent / "scripts/office"
sys.path.insert(0, str(office))
from archive import temporary_extract
from validators import PPTXSchemaValidator

ROOT = Path(__file__).resolve().parents[1]
P = "http://schemas.openxmlformats.org/presentationml/2006/main"
C = "http://schemas.openxmlformats.org/drawingml/2006/chart"


def command(entry, language, script, *parameters):
    return qualification.command(entry.parent, entry.name, [language, script, *parameters], os.environ, timeout=90)


def fingerprint(path):
    data = path.read_bytes()
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def validate(path):
    result = command(python_entry, "python", office / "validate.py", path)
    return {"exit_code": result.returncode, "passed": result.returncode == 0,
            "diagnostic": (result.stdout + result.stderr)[-8000:]}


def schema_scope(path):
    with temporary_extract(path) as extracted:
        with redirect_stdout(io.StringIO()):
            validator = PPTXSchemaValidator(extracted)
            results = []
            for part in [extracted / "ppt/presentation.xml", *sorted((extracted / "ppt/charts").glob("chart*.xml"))]:
                schema = validator._get_schema_path(part)
                tree = etree.parse(str(part))
                namespace = etree.QName(tree.getroot()).namespace
                expected_namespace = P if part.name == "presentation.xml" else C
                if namespace != expected_namespace or schema is None or not schema.is_file():
                    raise RuntimeError("Generated part is outside the declared schema scope")
                applicable, errors = validator._validate_single_file_xsd(part, extracted)
                results.append({"part": str(part.relative_to(extracted)), "namespace": namespace,
                                "schema": str(schema.relative_to(office)), "passed": applicable,
                                "errors": sorted(errors or [])})
            return results


def diagnostic_copy(source, destination):
    # Test-only counterfactual. Never applied to a user's file or bundled Skill.
    changes = []
    with zipfile.ZipFile(source) as packed:
        parts = {name: packed.read(name) for name in packed.namelist()}
    presentation = etree.fromstring(parts["ppt/presentation.xml"])
    notes, slides = presentation.find(f"{{{P}}}notesMasterIdLst"), presentation.find(f"{{{P}}}sldIdLst")
    if notes is not None and slides is not None and presentation.index(notes) > presentation.index(slides):
        presentation.remove(notes); presentation.insert(presentation.index(slides), notes)
        parts["ppt/presentation.xml"] = etree.tostring(presentation, xml_declaration=True, encoding="UTF-8", standalone=True)
        changes.append("presentation: notesMasterIdLst before sldIdLst")
    for name in sorted(parts):
        if not (name.startswith("ppt/charts/chart") and name.endswith(".xml")):
            continue
        chart = etree.fromstring(parts[name]); changed = False
        for series in chart.iter(f"{{{C}}}ser"):
            labels = series.find(f"{{{C}}}dLbls")
            if labels is None:
                continue
            for point in list(series.findall(f"{{{C}}}dPt")):
                if series.index(point) > series.index(labels):
                    series.remove(point); series.insert(series.index(labels), point); changed = True
                    changes.append(name + ": data point before series labels")
        for plot in chart.iter(f"{{{C}}}plotArea"):
            defined = {axis.find(f"{{{C}}}axId").get("val") for axis in plot
                       if etree.QName(axis).localname in ("catAx", "valAx", "dateAx", "serAx") and axis.find(f"{{{C}}}axId") is not None}
            for shape in plot:
                if etree.QName(shape).localname not in ("barChart", "lineChart"):
                    continue
                references = shape.findall(f"{{{C}}}axId")
                orphan = [axis for axis in references if axis.get("val") not in defined]
                if len(references) == 3 and len(defined) == 2 and len(orphan) == 1:
                    shape.remove(orphan[0]); changed = True
                    changes.append(name + ": removed undefined 2D axis reference " + orphan[0].get("val"))
        if changed:
            parts[name] = etree.tostring(chart, xml_declaration=True, encoding="UTF-8", standalone=True)
    with zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED) as packed:
        for name, data in parts.items():
            packed.writestr(name, data)
    return changes


with tempfile.TemporaryDirectory(prefix="office-generation-") as directory:
    work = Path(directory)
    generated = command(node_entry, "node", ROOT / "tests/fixtures/office/generation.cjs", work)
    if generated.returncode:
        raise RuntimeError("Fixed Node generator failed: " + generated.stderr[:2000])
    identity = json.loads(generated.stdout)
    results = []
    for path in sorted(work.iterdir()):
        if path.suffix not in (".docx", ".pptx"):
            continue
        before = path.read_bytes()
        item = {"case": path.name, "input": fingerprint(path), "validation": validate(path)}
        if path.suffix == ".pptx":
            item["applicable_schema_parts"] = schema_scope(path)
            with zipfile.ZipFile(path) as original:
                edited_parts = {name: original.read(name) for name in original.namelist()}
            target = "ppt/slides/slide1.xml"
            text = "Office 中文验收" if path.stem.startswith("text") else "Independent chart qualification"
            if edited_parts[target].count(text.encode("utf-8")) != 1:
                raise RuntimeError("PPTX targeted text is ambiguous")
            edited_parts[target] = edited_parts[target].replace(text.encode("utf-8"), b"Edited qualification text")
            edited = work / (path.stem + "-edited.pptx")
            with zipfile.ZipFile(edited, "x", zipfile.ZIP_DEFLATED) as packed:
                for name, data in edited_parts.items(): packed.writestr(name, data)
            with zipfile.ZipFile(path) as original, zipfile.ZipFile(edited) as modified:
                if any(original.read(name) != modified.read(name) for name in original.namelist() if name != target):
                    raise RuntimeError("PPTX unrelated relationship/data/part changed")
            item["targeted_edit"] = {**validate(edited), "all_other_parts_identical": True}
            diagnostic = work / (path.stem + "-diagnostic.pptx")
            item["diagnostic_copy"] = {"changes": diagnostic_copy(path, diagnostic), "validation": validate(diagnostic),
                                       "production_fix": False, "viewer_verified": False}
        else:
            with zipfile.ZipFile(path) as original:
                parts = {name: original.read(name) for name in original.namelist()}
            if parts["word/document.xml"].count(b"Original paragraph") != 1:
                raise RuntimeError("DOCX targeted text is ambiguous")
            parts["word/document.xml"] = parts["word/document.xml"].replace(b"Original paragraph", b"Edited paragraph")
            edited = work / "edited.docx"
            with zipfile.ZipFile(edited, "x", zipfile.ZIP_DEFLATED) as packed:
                for name, data in parts.items(): packed.writestr(name, data)
            with zipfile.ZipFile(path) as original, zipfile.ZipFile(edited) as modified:
                if any(original.read(name) != modified.read(name) for name in original.namelist() if name != "word/document.xml"):
                    raise RuntimeError("DOCX unrelated part changed")
            item["targeted_edit"] = validate(edited)
            read_output = work / "edited-read.json"
            read = command(python_entry, "python", python_entry.parent / "read.py", edited, read_output)
            read_text = read_output.read_text(encoding="utf-8") if read_output.is_file() else ""
            item["read_after_edit"] = {"exit_code": read.returncode, "chinese_table_and_edit_present": read.returncode == 0 and all(text in read_text for text in ("中文验收", "地区", "300", "Edited paragraph"))}
        if path.read_bytes() != before:
            raise RuntimeError("Original changed")
        item["original_unchanged"] = True
        results.append(item)
    report = {"version": 1, "host": qualification.native_target(), "python": sys.version.split()[0], "generators": identity, "inputs": {"probe": fingerprint(Path(__file__)), "generator": fingerprint(ROOT / "tests/fixtures/office/generation.cjs"), "archive": fingerprint(ROOT / "src/app/office-skills.tar.gz"), "environment": fingerprint(ROOT / "build_support/office-environment.json")}, "schema_policy": "Unmodified Transitional part schemas; no original-error subtraction or auto-repair", "viewer_evidence": None, "cases": results,
              "qualified": all(item["validation"]["passed"] and item.get("targeted_edit", {"passed": True})["passed"] and item.get("read_after_edit", {"chinese_table_and_edit_present": True})["chinese_table_and_edit_present"] for item in results)}
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(report, output, ensure_ascii=False, indent=2); output.write("\n")
    print(json.dumps({"qualified": report["qualified"], "cases": len(results), "failed": [item["case"] for item in results if not item["validation"]["passed"]], "report": str(args.report)}))
    raise SystemExit(0 if report["qualified"] else 1)
