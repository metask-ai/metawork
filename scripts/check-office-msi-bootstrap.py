"""Deterministic MSI path and real Windows CAB failure regressions.

Run with an explicit builder or verified portable Python, with -I -S -B.
The full vendor MSI parity and Host cancellation probes are separate evidence.
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("office_msi", REPO / "src/app/office_bootstrap/msi.py")
msi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(msi)


class Paths(unittest.TestCase):
    def test_source_names_do_not_use_target_system_folder_properties(self):
        self.assertEqual(msi.directory_paths([
            ("TARGETDIR", "", "SourceDir"),
            ("System", "TARGETDIR", "target:SHORT|PrivateSystem"),
            ("Flat", "System", "."),
        ]), {"TARGETDIR": (), "System": ("PrivateSystem",), "Flat": ("PrivateSystem",)})

    def test_path_escape_ads_devices_and_trailing_aliases_are_rejected(self):
        for name in ("..", "x/y", "x\\y", "C:", "a:stream", "NUL.txt", "com1", "a.", "a ", "x\x00y"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                msi.component(name)
        self.assertEqual(msi.component("中文-文件.dll"), "中文-文件.dll")

    def test_cycles_missing_parents_multiple_roots_and_duplicate_keys_are_rejected(self):
        for rows in (
            [("A", "B", "a"), ("B", "A", "b")],
            [("A", "MISSING", "a")],
            [("TARGETDIR", "", "SourceDir"), ("Other", "", "root")],
            [("TARGETDIR", "", "SourceDir"), ("TARGETDIR", "", "Other")],
        ):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                msi.directory_paths(rows)


@unittest.skipUnless(os.name == "nt", "Windows CAB API")
class Cabinet(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="metawork-office-msi-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.input = self.root / "fixture.bin"
        self.input.write_bytes(b"fixed binary fixture\n")
        self.cabinet = self.root / "fixture.cab"
        system = Path(os.environ["SystemRoot"]) / "System32"
        subprocess.run([str(system / "makecab.exe"), str(self.input), str(self.cabinet)],
                       check=True, cwd=self.root, capture_output=True, timeout=30,
                       creationflags=subprocess.CREATE_NO_WINDOW)
        self.output = self.root / "output"
        self.output.mkdir()
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()

    def test_real_cab_extracts_to_the_owned_directory_and_leaves_scratch_empty(self):
        previous = Path.cwd()
        msi.extract_cabinet(self.cabinet, {"fixture.bin": (("nested", "result.bin"), self.input.stat().st_size)}, self.output, self.scratch)
        self.assertEqual((self.output / "nested/result.bin").read_bytes(), self.input.read_bytes())
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertEqual(Path.cwd(), previous)

    def test_unknown_cab_member_and_wrong_size_fail_without_writing_output(self):
        for files in ({"unknown": (("file",), self.input.stat().st_size)},
                      {"fixture.bin": (("file",), self.input.stat().st_size + 1)}):
            with self.subTest(files=files), self.assertRaises(ValueError):
                msi.extract_cabinet(self.cabinet, files, self.output, self.scratch)
            self.assertEqual(list(self.output.iterdir()), [])
            self.assertEqual(list(self.scratch.iterdir()), [])

    def test_explicit_exclusion_skips_bytes_but_still_checks_the_declared_size(self):
        msi.extract_cabinet(self.cabinet, {"fixture.bin": (None, self.input.stat().st_size)}, self.output, self.scratch)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_existing_destination_is_preserved_on_collision(self):
        (self.output / "result.bin").write_bytes(b"original")
        with self.assertRaises(ValueError):
            msi.extract_cabinet(self.cabinet, {"fixture.bin": (("result.bin",), self.input.stat().st_size)}, self.output, self.scratch)
        self.assertEqual((self.output / "result.bin").read_bytes(), b"original")

    def test_bad_source_identity_fails_before_msi_parse_or_destination_creation(self):
        destination = self.root / "not-created"
        with self.assertRaisesRegex(ValueError, "pinned source"):
            msi.extract(self.input, destination, self.scratch, self.input.stat().st_size, "0" * 64)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertEqual(hashlib.sha256(self.input.read_bytes()).hexdigest(), hashlib.sha256(b"fixed binary fixture\n").hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
