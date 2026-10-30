"""Qualify the PPTX authoring/finalization chain through fixed private entries.

Usage: <Python run> python scripts/check-office-pptx.py
       --entry <Python run> --node-entry <Node run>
Synthetic data, retained viewer evidence, and invalid counterexamples only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from lxml import etree as E

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--entry", required=True, type=Path)
parser.add_argument("--node-entry", required=True, type=Path)
args, remaining = parser.parse_known_args()
ENTRY, NODE = args.entry.resolve(strict=True), args.node_entry.resolve(strict=True)
FINALIZE = ENTRY.parent.parent / "scripts/finalize.py"
VALIDATE = ENTRY.parent.parent / "scripts/office/validate.py"
P = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
C = "{http://schemas.openxmlformats.org/drawingml/2006/chart}"


def invoke(entry, language, script, *arguments):
    prefix = ["/bin/sh", str(entry)] if entry.suffix == ".sh" else [str(entry)]
    return subprocess.run(prefix + [language, str(script), *map(str, arguments)],
                          text=True, capture_output=True, timeout=90)


def parts(path):
    with zipfile.ZipFile(path) as packed:
        return {name: packed.read(name) for name in packed.namelist() if not name.endswith("/")}


def chart_content(data):
    tree = E.fromstring(data)
    # Independent observation of content/formulas, per-point styles and marker
    # settings. It does not reuse finalizer matching or its edits list.
    return {tag: [E.tostring(item, method="c14n") for item in tree.iter(C + tag)]
            for tag in ("cat", "val", "tx", "dPt", "dLbls", "marker", "spPr", "externalData")}


class PPTXQualification(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="office-pptx-tests-")
        cls.work = Path(cls.temporary.name)
        cls.generated = cls.work / "generated"
        result = invoke(NODE, "node", ROOT / "tests/fixtures/office/generation.cjs", cls.generated)
        if result.returncode:
            raise RuntimeError("Fixed Node generation failed: " + result.stderr[:1000])

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.local = Path(tempfile.mkdtemp(dir=self.work))

    def finalize(self, source, output=None, *, grouping=True):
        output = output or self.local / "checked.pptx"
        command = [source, output] + (["--line-grouping", "standard"] if grouping else [])
        return invoke(ENTRY, "python", FINALIZE, *command), output

    def mutated(self, stem, operation):
        content = parts(self.generated / (stem + ".pptx"))
        operation(content)
        path = self.local / "mutated.pptx"
        with zipfile.ZipFile(path, "x", zipfile.ZIP_DEFLATED) as packed:
            for name, data in content.items():
                packed.writestr(name, data)
        return path

    def test_representative_create_edit_and_preservation(self):
        for source in sorted(self.generated.glob("*.pptx")):
            with self.subTest(source=source.name):
                output = self.local / source.name
                before = source.read_bytes()
                result, _ = self.finalize(source, output)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["status"], "structure_passed")
                self.assertEqual(report["candidate"], {"bytes": output.stat().st_size,
                                 "sha256": hashlib.sha256(output.read_bytes()).hexdigest()})
                self.assertEqual(report["visual_check"], "not_performed")
                original, checked = parts(source), parts(output)
                self.assertEqual(set(original), set(checked))
                for name in original:
                    if name == "ppt/presentation.xml":
                        a, b = E.fromstring(original[name]), E.fromstring(checked[name])
                        self.assertEqual({item.tag: E.tostring(item, method="c14n") for item in a},
                                         {item.tag: E.tostring(item, method="c14n") for item in b})
                    elif name.startswith("ppt/charts/") and name.endswith(".xml"):
                        self.assertEqual(chart_content(original[name]), chart_content(checked[name]))
                    else:
                        self.assertEqual(original[name], checked[name], name)
                # A targeted edit of the actual finalized file must pass again;
                # failure of the original generator is retained as a baseline.
                title = "Office 中文验收" if source.stem.startswith("text") else "Independent chart qualification"
                self.assertEqual(checked["ppt/slides/slide1.xml"].count(title.encode()), 1)
                checked["ppt/slides/slide1.xml"] = checked["ppt/slides/slide1.xml"].replace(title.encode(), b"Edited title")
                edited = self.local / (source.stem + "-edited.pptx")
                with zipfile.ZipFile(edited, "x", zipfile.ZIP_DEFLATED) as packed:
                    for name, data in checked.items(): packed.writestr(name, data)
                validated = invoke(ENTRY, "python", VALIDATE, edited)
                self.assertEqual(validated.returncode, 0, validated.stdout + validated.stderr)
                self.assertEqual(source.read_bytes(), before)

    def test_no_implicit_line_grouping(self):
        result, output = self.finalize(self.generated / "line-multi-labels.pptx", grouping=False)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("explicitly declared", result.stdout)
        self.assertFalse(output.exists())

    def test_exclusive_output_and_original_protection(self):
        source = self.generated / "text-notes.pptx"
        before = source.read_bytes()
        for output in (source, self.local / "existing.pptx", self.local / "alias.pptx"):
            if output != source:
                if output.stem == "alias": output.hardlink_to(source)
                else: output.write_bytes(b"existing")
            content = output.read_bytes()
            result, _ = self.finalize(source, output)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(output.read_bytes(), content)
        self.assertEqual(source.read_bytes(), before)

    def test_unknown_patterns_and_unrelated_errors_cannot_become_success(self):
        def chart_mutation(content, action):
            name = next(n for n in content if n.startswith("ppt/charts/chart") and n.endswith(".xml"))
            tree = E.fromstring(content[name]); action(tree)
            content[name] = E.tostring(tree)
        def wrong_cross(tree):
            next(tree.iter(C + "crossAx")).set("val", "123")
        def duplicate_axis(tree):
            shape = next(tree.iter(C + "barChart"))
            shape.append(E.fromstring(E.tostring(shape.findall(C + "axId")[0])))
        def true_invert(tree):
            next(tree.iter(C + "invertIfNegative")).set("val", "1")
        def stacked_line(tree):
            next(tree.iter(C + "lineChart")).insert(0, E.Element(C + "grouping", val="stacked"))
        def duplicate_point(tree):
            series = next(tree.iter(C + "ser"))
            point = next(series.iter(C + "dPt"))
            series.append(E.fromstring(E.tostring(point)))
        def notes_order(content):
            tree = E.fromstring(content["ppt/presentation.xml"])
            notes = tree.find(P + "notesMasterIdLst")
            tree.remove(notes); tree.append(notes)
            content["ppt/presentation.xml"] = E.tostring(tree)
        def unrelated(content):
            content["ppt/slides/slide1.xml"] = content["ppt/slides/slide1.xml"].replace(b"<p:cSld", b"<p:bogus", 1).replace(b"</p:cSld>", b"</p:bogus>", 1)
        for index, (stem, mutate) in enumerate((
                ("bar-multi-labels", lambda p: chart_mutation(p, wrong_cross)),
                ("bar-multi-labels", lambda p: chart_mutation(p, duplicate_axis)),
                ("bar-multi-labels", lambda p: chart_mutation(p, duplicate_point)),
                ("line-multi-labels", lambda p: chart_mutation(p, true_invert)),
                ("line-multi-labels", lambda p: chart_mutation(p, stacked_line)),
                ("text-notes", notes_order),
                ("text-notes", unrelated))):
            with self.subTest(index=index):
                self.local = Path(tempfile.mkdtemp(dir=self.work))
                source = self.mutated(stem, mutate)
                before = source.read_bytes()
                result, output = self.finalize(source)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(output.exists())
                self.assertEqual(source.read_bytes(), before)

    def test_unsafe_archive_and_xml_fail_before_publication(self):
        for name, content in (("../outside", b"data"),
                              ("ppt/presentation.xml", b'<!DOCTYPE p [<!ENTITY x "secret">]><p>&x;</p>')):
            self.local = Path(tempfile.mkdtemp(dir=self.work))
            source = self.local / "unsafe.pptx"
            with zipfile.ZipFile(source, "x") as packed: packed.writestr(name, content)
            result, output = self.finalize(source)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertNotIn("secret", result.stdout + result.stderr)

    def test_retained_viewer_evidence_identity_and_structure(self):
        report = json.loads((ROOT / "docs/evidence/office-pptx-metaskoffice-20261030.json").read_text())
        for case in report["qualification"]["cases"]:
            for file in case["files"]:
                path = ROOT / file["path"]
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), file["sha256"])
                self.assertEqual(path.stat().st_size, file["bytes"])
                result = invoke(ENTRY, "python", VALIDATE, path)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


unittest.main(argv=[sys.argv[0], *remaining])
