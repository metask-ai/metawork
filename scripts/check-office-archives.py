"""Behavioral tests of the shared bounded archive implementation."""
import dataclasses
import hashlib
import importlib.util
import os
import stat
import struct
import sys
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("bounded_archive", ROOT / "src/product/skill/assets/zip/scripts/archive.py")
archive = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = archive
SPEC.loader.exec_module(archive)


class Archives(unittest.TestCase):
    def setUp(self):
        base = ROOT / ".zig-cache/office-archive-tests"
        base.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=base)
        self.previous = Path.cwd()
        os.chdir(self.scratch.name)

    def tearDown(self):
        os.chdir(self.previous)
        self.scratch.cleanup()

    def make(self, entries, compression=zipfile.ZIP_DEFLATED):
        with zipfile.ZipFile("input.zip", "w", compression=compression) as output:
            for name, content in entries:
                output.writestr(name, content)
        return Path("input.zip")

    def rejected(self, source, **options):
        with self.assertRaises((archive.ArchiveError, ValueError, zipfile.BadZipFile, FileExistsError)):
            archive.safe_extract(source, "output", **options)
        self.assertFalse(Path("output").exists())

    def test_regular_files_and_nested_skill_data_are_unchanged(self):
        for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            source = self.make([("notes.txt", b"hello"), (".agents/skills/data/SKILL.md", b"untrusted instructions"), ("binary.bin", b"\x00\xff")], compression)
            before = hashlib.sha256(source.read_bytes()).digest()
            listing = archive.list_archive(source, limit=1)
            self.assertEqual(listing["members"], 3)
            self.assertEqual(listing["nextOffset"], 1)
            result = archive.safe_extract(source, "data")
            self.assertEqual(result["bytes"], 29)
            self.assertEqual(Path("data/.agents/skills/data/SKILL.md").read_bytes(), b"untrusted instructions")
            self.assertEqual(Path("data/binary.bin").read_bytes(), b"\x00\xff")
            self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
            import shutil
            shutil.rmtree("data")

    def test_paths_collisions_links_and_unsupported_compression(self):
        for name in ("../escape", "/absolute", "C:/drive", "a\\b", "a/../b", "CON.txt", "a./b"):
            with self.subTest(name=name):
                self.rejected(self.make([(name, b"data")]))
        source = self.make([("axb", b"data")])
        data = bytearray(source.read_bytes())
        central = data.index(b"PK\x01\x02")
        data[30:33] = b"a\x00b"
        data[central + 46:central + 49] = b"a\x00b"
        source.write_bytes(data)
        self.rejected(source)
        for names in (("A.txt", "a.txt"), ("a", "a/child"), ("a/first", "A/second")):
            self.rejected(self.make([(name, b"data") for name in names]))
        for kind in (stat.S_IFLNK, stat.S_IFIFO):
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (kind | 0o777) << 16
            self.rejected(self.make([(info, b"../escape")]))
        info = zipfile.ZipInfo("hardlink")
        info.extra = struct.pack("<HH", 0x000d, 13) + b"x" * 13
        self.rejected(self.make([(info, b"data")]))
        self.rejected(self.make([("data", b"data")], zipfile.ZIP_BZIP2))

    def test_existing_destination_and_skill_source_are_not_modified(self):
        source = self.make([("data", b"new")])
        Path("output").mkdir()
        Path("output/keep").write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            archive.safe_extract(source, "output")
        self.assertEqual(Path("output/keep").read_bytes(), b"keep")
        for destination in (".agents", ".CLAUDE", ".codex", "../outside"):
            with self.assertRaises((archive.ArchiveError, ValueError)):
                archive.safe_extract(source, destination)

    def test_member_metadata_and_declared_byte_budgets(self):
        source = self.make([("one", b"a"), ("two", b"b")])
        self.rejected(source, limits=dataclasses.replace(archive.DEFAULT_LIMITS, members=1))
        with patch.object(archive.zipfile, "ZipFile") as parser:
            with self.assertRaises(archive.ArchiveError):
                archive.list_archive(source, limits=dataclasses.replace(archive.DEFAULT_LIMITS, metadata_bytes=1))
            parser.assert_not_called()
        self.rejected(source, limits=dataclasses.replace(archive.DEFAULT_LIMITS, total_bytes=1))

    def test_lying_member_count_is_rejected_before_the_library_allocates_members(self):
        source = self.make([("one", b"a"), ("two", b"b")])
        data = bytearray(source.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        struct.pack_into("<H", data, end + 8, 1)
        struct.pack_into("<H", data, end + 10, 1)
        source.write_bytes(data)
        with patch.object(archive.zipfile, "ZipFile") as parser:
            with self.assertRaises(archive.ArchiveError):
                archive.list_archive(source)
            parser.assert_not_called()

    def test_actual_expansion_is_bounded_even_when_directory_size_lies(self):
        source = self.make([("large", b"A" * 4096)])
        data = bytearray(source.read_bytes())
        central = data.index(b"PK\x01\x02")
        struct.pack_into("<L", data, central + 24, 1)
        struct.pack_into("<L", data, 22, 1)
        source.write_bytes(data)
        self.assertEqual(archive.list_archive(source)["declaredBytes"], 1)
        with self.assertRaisesRegex(archive.ArchiveError, "Actual ZIP"):
            archive.safe_extract(source, "output", dataclasses.replace(archive.DEFAULT_LIMITS, member_bytes=512, total_bytes=1024))
        self.assertFalse(Path("output").exists())

    def test_corrupt_payload_crc_and_zip64_leave_no_partial_output(self):
        source = self.make([("one", b"first"), ("two", b"second")])
        data = bytearray(source.read_bytes())
        second = data.index(b"PK\x01\x02", data.index(b"PK\x01\x02") + 1)
        struct.pack_into("<L", data, second + 16, 0)
        source.write_bytes(data)
        self.rejected(source)

        source = self.make([("one", b"first")])
        data = bytearray(source.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        struct.pack_into("<H", data, end + 10, 65535)
        source.write_bytes(data)
        self.rejected(source)

    def test_all_office_entrypoints_reject_traversal_without_partial_output(self):
        source = self.make([("../escape", b"data")])
        for skill in ("docx", "xlsx", "pptx"):
            document = Path(f"input.{skill}")
            document.write_bytes(source.read_bytes())
            result = subprocess.run([
                sys.executable, "-B", str(ROOT / f"src/product/skill/assets/{skill}/scripts/office/unpack.py"),
                str(document), f"unpacked-{skill}",
            ], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(Path(f"unpacked-{skill}").exists())
            self.assertFalse(Path("escape").exists())



if __name__ == "__main__":
    unittest.main()
