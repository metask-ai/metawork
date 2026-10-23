"""Deterministic offline dependency assembly and hostile archive regression."""
import base64
import csv
from dataclasses import replace
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src/app/office_bootstrap"))
import packages

HELPER = ROOT / "src/product/control/resources/archive.py"


class PackageBootstrap(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".zig-cache/office-package-bootstrap-tests"
        cache.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="run-", dir=cache)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()

    def wheel(self, changes=None, *, version="1.0", record_changes=None):
        files = {"demo/__init__.py": b"raise RuntimeError('package code must not execute')\n",
                 "demo-1.0.dist-info/METADATA": f"Name: demo\nVersion: {version}\n".encode(),
                 "demo-1.0.dist-info/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
                 "demo-1.0.dist-info/entry_points.txt": b"[console_scripts]\ndemo=demo:main\n",
                 "demo-1.0.data/scripts/demo.py": b"raise RuntimeError('script must not execute')\n"}
        files.update(changes or {})
        rows = [[name, "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(value).digest()).rstrip(b"=").decode(), str(len(value))]
                for name, value in sorted(files.items())]
        records = io.StringIO(newline="")
        writer = csv.writer(records, lineterminator="\n")
        writer.writerows(rows)
        writer.writerow(["demo-1.0.dist-info/RECORD", "", ""])
        files["demo-1.0.dist-info/RECORD"] = records.getvalue().encode()
        files.update(record_changes or {})
        target = self.downloads / "demo.whl"
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, value in files.items():
                archive.writestr(name, value)
        return {"name": "demo", "version": "1.0", "source": target.name,
                "algorithm": "sha256", "digest": packages.file_digest(target)}

    def npm(self, members=None, *, version="1.0.0", trailing=b""):
        body = io.BytesIO()
        with tarfile.open(fileobj=body, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name, value, kind in members or [
                    ("package/package.json", json.dumps({"name": "demo", "version": version}).encode(), tarfile.REGTYPE),
                    ("package/index.js", b"throw Error('package code must not execute');", tarfile.REGTYPE)]:
                info = tarfile.TarInfo(name)
                info.type = kind
                info.size = len(value) if kind == tarfile.REGTYPE else 0
                info.linkname = "../outside" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
                archive.addfile(info, io.BytesIO(value) if info.size else None)
        target = self.downloads / "demo.tgz"
        target.write_bytes(gzip.compress(body.getvalue() + trailing, mtime=0))
        return {"name": "demo", "version": "1.0.0", "location": "node_modules/demo",
                "source": target.name, "algorithm": "sha512", "digest": packages.file_digest(target, "sha512")}

    def recipe(self, wheel=None, npm=None):
        return {"schema": 1, "target": "x86_64-windows-msvc", "archiveHelperSha256": packages.file_digest(HELPER),
                "python": [] if wheel is None else [wheel], "javascript": [] if npm is None else [npm],
                "authoring": {"manifest": {"name": "synthetic"}, "lock": {"lockfileVersion": 3}}}

    def assemble(self, recipe, name="output", limits=packages.Limits()):
        destination = self.root / name
        destination.mkdir()
        result = packages.assemble(recipe, self.downloads, destination, HELPER, limits)
        files = [path for path in destination.rglob("*") if path.is_file()]
        self.assertEqual(result["files"], len(files))
        self.assertEqual(result["bytes"], sum(path.stat().st_size for path in files))
        self.assertFalse((destination / "office-runtime.json").exists())
        return destination

    def rejected(self, recipe, limits=packages.Limits()):
        with self.assertRaises((ValueError, EOFError, tarfile.TarError, zipfile.BadZipFile)):
            self.assemble(recipe, limits=limits)
        self.assertFalse((self.root / "outside").exists())

    def test_identical_files_in_different_roots_without_executing_code_or_rewriting_record(self):
        wheel, npm = self.wheel(), self.npm()
        recipe = self.recipe(wheel, npm)
        first = self.assemble(recipe, "first")
        second = self.assemble(recipe, "different second root")
        inventory = lambda root: {path.relative_to(root).as_posix(): packages.file_digest(path)
                                  for path in root.rglob("*") if path.is_file()}
        self.assertEqual(inventory(first), inventory(second))
        with zipfile.ZipFile(self.downloads / "demo.whl") as archive:
            self.assertEqual((first / "python-packages/demo-1.0.dist-info/RECORD").read_bytes(),
                             archive.read("demo-1.0.dist-info/RECORD"))
        self.assertFalse((first / "python-packages/bin").exists())
        self.assertFalse((first / "authoring/node_modules/.bin").exists())

    def test_source_digest_and_parent_escape_fail_before_package_output(self):
        entry = self.wheel()
        for key, value in (("digest", "0" * 64), ("source", "../outside")):
            with self.subTest(key=key):
                case = self.root / key
                case.mkdir()
                with self.assertRaises(ValueError):
                    packages.assemble(self.recipe({**entry, key: value}), self.downloads, case, HELPER)
                self.assertFalse((case / "python-packages").exists())

    def test_helper_bytes_must_match_before_import(self):
        recipe = self.recipe(self.wheel())
        recipe["archiveHelperSha256"] = "0" * 64
        self.rejected(recipe)

    def test_wheel_record_tampering_is_rejected(self):
        self.rejected(self.recipe(self.wheel(record_changes={"demo/__init__.py": b"changed"})))

    def test_wheel_version_mismatch_is_rejected(self):
        self.rejected(self.recipe(self.wheel(version="2.0")))

    def test_wheel_data_relocation_is_explicitly_unsupported(self):
        self.rejected(self.recipe(self.wheel({"demo-1.0.data/purelib/shadow.py": b"pass"})))

    def test_zip_unsafe_path_and_case_collision_use_existing_archive_gate(self):
        for name in ("../outside", "DEMO/__init__.py", "CON.py"):
            with self.subTest(name=name):
                case = self.root / ("case-" + str(len(list(self.root.iterdir()))))
                case.mkdir()
                with self.assertRaises(ValueError):
                    packages.assemble(self.recipe(self.wheel({name: b"bad"})), self.downloads, case, HELPER)

    def test_npm_links_and_path_escape_are_rejected(self):
        for name, kind in (("package/../outside", tarfile.REGTYPE), ("elsewhere/file", tarfile.REGTYPE),
                           ("package/CON.txt", tarfile.REGTYPE), ("package/link", tarfile.SYMTYPE),
                           ("package/link", tarfile.LNKTYPE), ("package/device", tarfile.CHRTYPE)):
            with self.subTest(name=name, kind=kind):
                case = self.root / ("case-" + str(len(list(self.root.iterdir()))))
                case.mkdir()
                with self.assertRaises(ValueError):
                    packages.assemble(self.recipe(npm=self.npm([(name, b"bad", kind)])), self.downloads, case, HELPER)

    def test_npm_single_named_root_is_valid_but_multiple_roots_are_rejected(self):
        metadata = json.dumps({"name": "demo", "version": "1.0.0"}).encode()
        members = [("node/package.json", metadata, tarfile.REGTYPE), ("node/index.js", b"module.exports=1", tarfile.REGTYPE)]
        self.assemble(self.recipe(npm=self.npm(members)), "named-root")
        members.append(("elsewhere/file", b"bad", tarfile.REGTYPE))
        self.rejected(self.recipe(npm=self.npm(members)))

    def test_duplicate_npm_member_and_bundled_dependency_are_rejected(self):
        for members in ([('package/file', b'a', tarfile.REGTYPE), ('package/file', b'b', tarfile.REGTYPE)],
                        [('package/node_modules/other/file', b'bad', tarfile.REGTYPE)]):
            case = self.root / ("case-" + str(len(list(self.root.iterdir()))))
            case.mkdir()
            with self.assertRaises(ValueError):
                packages.assemble(self.recipe(npm=self.npm(members)), self.downloads, case, HELPER)

    def test_npm_version_and_nonzero_trailing_data_are_rejected(self):
        for create in (lambda: self.npm(version="2.0.0"), lambda: self.npm(trailing=b"hidden")):
            case = self.root / ("case-" + str(len(list(self.root.iterdir()))))
            case.mkdir()
            with self.assertRaises(ValueError):
                packages.assemble(self.recipe(npm=create()), self.downloads, case, HELPER)

    def test_aggregate_member_bytes_and_compressed_limits_are_rejected(self):
        recipe = self.recipe(self.wheel(), self.npm())
        for changes in ({"members": 6}, {"expanded_bytes": 32}, {"compressed_bytes": 32}, {"sources": 1}):
            case = self.root / ("case-" + str(len(list(self.root.iterdir()))))
            case.mkdir()
            with self.assertRaises(ValueError):
                packages.assemble(recipe, self.downloads, case, HELPER, replace(packages.Limits(), **changes))

    def test_pax_declared_metadata_is_bounded_before_payload_read(self):
        entry = self.npm()
        info = tarfile.TarInfo("metadata")
        info.type = tarfile.XHDTYPE
        info.size = 1024**3
        source = self.downloads / entry["source"]
        source.write_bytes(gzip.compress(info.tobuf(), mtime=0))
        entry["digest"] = packages.file_digest(source, "sha512")
        self.rejected(self.recipe(npm=entry))

    def test_existing_dependency_tree_is_never_overwritten(self):
        output = self.root / "output"
        output.mkdir()
        (output / "python-packages").mkdir()
        marker = output / "python-packages/keep"
        marker.write_bytes(b"original")
        with self.assertRaises(ValueError):
            packages.assemble(self.recipe(self.wheel()), self.downloads, output, HELPER)
        self.assertEqual(marker.read_bytes(), b"original")

    def test_reparse_source_parent_and_output_root_are_rejected(self):
        entry = self.wheel()
        actual = self.downloads / "actual"
        actual.mkdir()
        (actual / "demo.whl").write_bytes((self.downloads / "demo.whl").read_bytes())
        output = self.root / "actual-output"
        output.mkdir()
        for link, target in ((self.downloads / "alias", actual), (self.root / "output-alias", output)):
            subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(link), str(target)],
                           check=True, capture_output=True, timeout=10)
            self.addCleanup(link.rmdir)  # Only the owned junction, never its target.
        self.rejected(self.recipe({**entry, "source": "alias/demo.whl"}))
        with self.assertRaises(ValueError):
            packages.assemble(self.recipe(entry), self.downloads, self.root / "output-alias", HELPER)
        self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    if os.name != "nt":
        raise SystemExit("Windows qualification is required")
    unittest.main(verbosity=2)
