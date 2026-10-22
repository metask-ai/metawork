"""Regression cases for the release archive's independently checked bytes."""
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("office_component_archive", Path(__file__).with_name("check-office-component-archive.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ComponentArchive(unittest.TestCase):
    def make_archive(self, directory, *, payload=b"runtime", manifest_digest=None, name="bin/office.exe",
                     link=False, trailing=b"", crc=False):
        manifest = {"schema": 1, "target": "x86_64-windows-msvc", "payloadBytes": len(payload),
                    "files": [{"path": name, "bytes": len(payload),
                               "sha256": manifest_digest or hashlib.sha256(payload).hexdigest()}]}
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            entry = tarfile.TarInfo(name)
            if link:
                entry.type = tarfile.SYMTYPE
                entry.linkname = "../outside"
                archive.addfile(entry)
            else:
                entry.size = len(payload)
                archive.addfile(entry, io.BytesIO(payload))
            data = json.dumps(manifest).encode("utf-8")
            entry = tarfile.TarInfo("office-runtime.json")
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        compressed = bytearray(gzip.compress(stream.getvalue() + trailing))
        if crc:
            compressed[-8] ^= 1
        path = Path(directory) / "component.tar.gz"
        path.write_bytes(compressed)
        return path

    def test_manifest_is_checked_against_same_actual_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            result = checker.verify(self.make_archive(directory))
            self.assertEqual(result["files"], 2)
            with self.assertRaisesRegex(ValueError, "manifest differs"):
                checker.verify(self.make_archive(directory, manifest_digest="0" * 64))

    def test_unsafe_paths_links_and_debug_files_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            for options in ({"name": "../escape"}, {"name": "C:/escape"}, {"link": True},
                            {"name": "bin/office.pdb"}, {"name": "python/cache.pyc"}):
                with self.subTest(options=options), self.assertRaises(ValueError):
                    checker.verify(self.make_archive(directory, **options))

    def test_tar_lookahead_cannot_hide_nonzero_trailing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "after component tar end"):
                checker.verify(self.make_archive(directory, trailing=b"unaccounted payload"))

    def test_gzip_crc_is_verified_beyond_logical_tar_end(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(gzip.BadGzipFile):
                checker.verify(self.make_archive(directory, crc=True))


if __name__ == "__main__":
    unittest.main()
