"""Regression checks for seed authentication and shared runtime mechanics.

Synthetic files exercise rejection and serialization only. Actual fixed MSI,
DLLs, archives and complete manifest equality require separate qualification.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/app/office_bootstrap"))
import assemble
import packages
import payload

HELPER = REPO / "src/product/control/resources/archive.py"


class InstallationAssembly(unittest.TestCase):
    def setUp(self):
        base = REPO / ".zig-cache/office-install-assembly-tests"
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def put(self, name, data=b"input"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def layout(self, *, extra=None):
        root = self.root / "component"
        self.put("component/engine/program/soffice.com")
        self.put("component/engine/program/python313.dll")
        self.put("component/engine/program/python3.dll")
        self.put("component/engine/program/python-core-3.13.15/bin/python.exe")
        self.put("component/engine/program/python-core-3.13.15/lib/example.py")
        self.put("component/engine/System64/runtime.dll", b"new runtime")
        self.put("component/engine/program/runtime.dll", b"old runtime")
        self.put("component/engine/Fonts/font.ttf")
        (root / "engine/program/python-core-3.13.15/lib/empty").mkdir()
        node = self.root / "node.zip"
        with zipfile.ZipFile(node, "w") as archive:
            archive.writestr("node-root/node.exe", b"node")
            archive.writestr("node-root/LICENSE", b"license")
            if extra:
                archive.writestr(extra, b"bad")
        sources = {"libreoffice": {"pythonDirectory": "python-core-3.13.15"}, "node": {"archiveRoot": "node-root"}}
        helper = packages.load_archive_helper(HELPER, packages.file_digest(HELPER))
        return root, node, self.put("font.otf"), self.put("license.txt"), sources, helper

    def test_shared_layout_preserves_empty_directories_and_known_vendor_dll_placement(self):
        inputs = self.layout()
        payload.layout(*inputs)
        root = inputs[0]
        self.assertTrue((root / "python/lib/empty").is_dir())
        self.assertEqual((root / "python/bin/runtime.dll").read_bytes(), b"new runtime")
        self.assertEqual((root / "engine/program/runtime.dll").read_bytes(), b"new runtime")
        self.assertEqual((root / "python/bin/python313._pth").read_bytes(), b"../lib\r\n")
        self.assertEqual((root / "node/node.exe").read_bytes(), b"node")

    def test_node_zip_path_traversal_is_rejected_by_canonical_helper(self):
        with self.assertRaises(ValueError):
            payload.layout(*self.layout(extra="../escape"))
        self.assertFalse((self.root / "escape").exists())

    def test_existing_runtime_output_is_not_overwritten(self):
        inputs = self.layout()
        self.put("component/python/keep", b"existing")
        with self.assertRaises(ValueError):
            payload.layout(*inputs)
        self.assertEqual((inputs[0] / "python/keep").read_bytes(), b"existing")

    def test_manifest_serialization_matches_existing_windows_producer(self):
        root = self.root / "component"
        self.put("component/z.txt")
        self.put("component/a/中文.txt", b"second")
        files = [{"path": file.relative_to(root).as_posix(), "bytes": file.stat().st_size,
                  "sha256": packages.file_digest(file)} for file in sorted(root.rglob("*")) if file.is_file()]
        legacy = (json.dumps({"schema": 1, "target": "x86_64-windows-msvc", "payloadBytes": 11, "files": files},
                             separators=(",", ":")) + "\r\n").encode("utf-8")
        self.assertEqual(payload.manifest_bytes(root), legacy)
        payload.write_manifest(root, hashlib.sha256(legacy).hexdigest())
        self.assertEqual((root / "office-runtime.json").read_bytes(), legacy)
        with self.assertRaises(ValueError):
            payload.write_manifest(root)

    def test_mismatching_final_manifest_is_never_written(self):
        self.put("component/file")
        root = self.root / "component"
        with self.assertRaises(ValueError):
            payload.write_manifest(root, "1" * 64)
        self.assertFalse((root / "office-runtime.json").exists())

    def test_archive_is_reproducible_and_existing_output_is_preserved(self):
        self.put("component/file")
        root = self.root / "component"
        payload.write_manifest(root)
        first, second = self.root / "one.tar.gz", self.root / "two.tar.gz"
        payload.write_archive(root, first)
        payload.write_archive(root, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with self.assertRaises(FileExistsError):
            payload.write_archive(root, first)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_archive_budget_failure_removes_only_the_new_output(self):
        self.put("component/file")
        root = self.root / "component"
        payload.write_manifest(root)
        output = self.root / "too-small.tar.gz"
        with self.assertRaises(ValueError):
            payload.write_archive(root, output, compressed_limit=1)
        self.assertFalse(output.exists())

    def test_seed_actual_aggregate_bytes_are_bounded(self):
        seed = self.root / "seed"
        for index in range(9):
            self.put("seed/bootstrap/" + str(index), bytes(1024**2))
        payload.write_manifest(seed)
        with self.assertRaisesRegex(ValueError, "Actual seed exceeds budget"):
            assemble.verify_seed(seed, packages.file_digest(seed / "office-runtime.json"))

    def test_seed_digest_tampering_and_extra_file_are_rejected(self):
        seed = self.root / "seed"
        self.put("seed/bootstrap/file")
        payload.write_manifest(seed)
        digest = packages.file_digest(seed / "office-runtime.json")
        assemble.verify_seed(seed, digest)
        with self.assertRaises(ValueError):
            assemble.verify_seed(seed, "1" * 64)
        self.put("seed/extra")
        with self.assertRaises(ValueError):
            assemble.verify_seed(seed, digest)
        (seed / "extra").unlink()
        self.put("seed/bootstrap/file", b"changed")
        with self.assertRaises(ValueError):
            assemble.verify_seed(seed, digest)

    def test_corrupt_public_source_fails_before_creating_component(self):
        seed = self.root / "seed"
        content = HELPER.read_bytes()
        self.put("seed/bootstrap/office_archive.py", content)
        entries = []
        for name in ("libreoffice", "node", "font", "fontLicense", "bootstrapPython"):
            self.put("downloads/" + name, b"bad")
            entries.append({"name": name, "path": name, "bytes": 3, "algorithm": "sha256", "digest": "1" * 64})
        plan = {"schema": 1, "target": "x86_64-windows-msvc", "manifestSha256": "2" * 64,
                "downloads": entries, "sources": {}, "recipe": {"archiveHelperSha256": hashlib.sha256(content).hexdigest()}}
        self.put("seed/bootstrap/plan.json", json.dumps(plan).encode())
        payload.write_manifest(seed)
        output = self.root / "component"
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            assemble.assemble(seed, self.root / "downloads", output, "2" * 64, packages.file_digest(seed / "office-runtime.json"))
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob(".assembly-*")))

    def test_runtime_inventory_rejects_junction_before_following_it(self):
        actual = self.root / "outside"
        actual.mkdir()
        root = self.root / "component"
        root.mkdir()
        link = root / "alias"
        subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(link), str(actual)], check=True, capture_output=True)
        self.addCleanup(link.rmdir)
        with self.assertRaises(ValueError):
            payload.manifest_bytes(root)
        self.assertEqual(list(actual.iterdir()), [])


if __name__ == "__main__":
    if os.name != "nt":
        raise SystemExit("Windows qualification required")
    unittest.main(verbosity=2)
