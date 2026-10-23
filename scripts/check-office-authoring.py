"""Check isolated authoring, structured reads and packaged self-test on Windows."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from openpyxl import Workbook

COMPONENT = Path(sys.argv.pop(1)).resolve(strict=True)
ROOT = Path(__file__).resolve().parents[1]


class OfficeAuthoring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = ROOT / ".zig-cache/office-authoring-regression"
        base.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="脚本 空格 ", dir=base)
        cls.root = Path(cls.temporary.name)
        cls.exe = COMPONENT / "bin/office.exe"

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def invoke(self, *arguments, env=None):
        result = subprocess.run([str(self.exe), *map(str, arguments)], cwd=self.root,
                                env=env, capture_output=True, text=True, encoding="utf-8", timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_python_uses_packaged_libraries_before_script_directory(self):
        (self.root / "openpyxl.py").write_text("raise RuntimeError('workspace shadow package')", encoding="utf-8")
        script = self.root / "author.py"
        script.write_text("import openpyxl,json,sys;print(json.dumps({'file':openpyxl.__file__,'args':sys.argv[1:]}))", encoding="utf-8")
        output = json.loads(self.invoke("python", script, "中文", 'quotes" and spaces'))
        self.assertTrue(Path(output["file"]).is_relative_to(COMPONENT / "python-packages"))
        self.assertEqual(output["args"], ["中文", 'quotes" and spaces'])

    def test_node_commonjs_and_esm_reject_workspace_shadow_and_inherited_options(self):
        fake = self.root / "node_modules/docx"
        fake.mkdir(parents=True)
        (fake / "package.json").write_text('{"name":"docx","main":"index.js"}', encoding="utf-8")
        (fake / "index.js").write_text("throw Error('workspace shadow package')", encoding="utf-8")
        environment = {**os.environ, "NODE_OPTIONS": "--require=does-not-exist-metawork",
                       "NODE_PATH": str(self.root / "node_modules")}
        cjs = self.root / "author.cjs"
        cjs.write_text("const docx=require('docx');if(!docx.Document)throw Error('missing');console.log(require.resolve('docx'));", encoding="utf-8")
        resolved = self.invoke("node", cjs, env=environment).strip()
        self.assertTrue(Path(resolved).is_relative_to(COMPONENT / "authoring/node_modules/docx"))
        esm = self.root / "author.mjs"
        esm.write_text("import {Document} from 'docx';import pptxgen from 'pptxgenjs';if(!Document||!pptxgen)throw Error('missing');console.log('ok');", encoding="utf-8")
        self.assertEqual(self.invoke("node", esm, env=environment).strip(), "ok")
        self.assertNotEqual(os.environ.get("NODE_OPTIONS"), environment["NODE_OPTIONS"])

    def test_structured_reads_preserve_formulas_and_caches_without_an_engine(self):
        source = self.root / "formula.xlsx"
        workbook = Workbook()
        workbook.active["A1"] = "中文"
        workbook.active["B2"] = "=1+1"
        workbook.save(source)
        workbook.close()
        original = source.read_bytes()
        output = self.root / "text.json"
        self.invoke("text", source, output)
        data = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(data["sheets"][0]["cells"], [
            {"cell": "A1", "value": "中文", "formula": False, "cached": "中文"},
            {"cell": "B2", "value": "=1+1", "formula": True, "cached": None},
        ])
        self.assertEqual(source.read_bytes(), original)

    def test_packaged_engine_font_and_authoring_selftest(self):
        result = json.loads(self.invoke("selftest"))
        sources = json.loads((ROOT / "build_support/office-runtime.windows-x64.sources.json").read_text(encoding="utf-8"))
        self.assertEqual(result["schema"], 1)
        self.assertEqual(result["font"], "Noto Sans CJK SC")
        self.assertEqual(result["python"], sources["libreoffice"]["pythonDirectory"].removeprefix("python-core-"))
        self.assertEqual(result["node"], sources["node"]["version"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
