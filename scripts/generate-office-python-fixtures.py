"""Generate small ZIP fixtures for the first-stage Python dialect."""
import hashlib
import io
import json
from pathlib import Path
import stat
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1] / "src/app/office_python_archive_fixtures"
ROOT.mkdir(exist_ok=True)


def archive(extra=()):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name, data, mode in [("python.exe", b"embedded-runtime", stat.S_IFREG | 0o644),
                                 ("python313.zip", b"library" * 4096, stat.S_IFREG | 0o644), *extra]:
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    return out.getvalue()


fixtures = {}


def emit(name, data, error=None):
    (ROOT / (name + ".zip")).write_bytes(data)
    fixtures[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "error": error}


raw = archive()
emit("valid", raw)
for name, path, mode, error in [
    ("traversal", "../escape", stat.S_IFREG, "ComponentPath"),
    ("backslash", "a\\outside", stat.S_IFREG, "ComponentPath"),
    ("reserved", "CON.txt", stat.S_IFREG, "ComponentPath"),
    ("nested", "dir/file.py", stat.S_IFREG, "PythonZipPath"),
    ("case-alias", "PYTHON.EXE", stat.S_IFREG, "PythonZipCollision"),
    ("symlink", "link", stat.S_IFLNK, "PythonZipFormat"),
    ("directory", "dir/", stat.S_IFDIR, "PythonZipFormat"),
]:
    data = archive([(path, b"bad", mode | 0o644)])
    # Windows ZipInfo normalizes backslashes. Mutate both identical filename
    # fields afterward so this actually tests a backslash on every builder.
    if name == "backslash":
        data = data.replace(b"a/outside", b"a\\outside")
    emit(name, data, error)

cd = struct.unpack_from("<I", raw, len(raw) - 6)[0]
name_len = struct.unpack_from("<H", raw, 26)[0]
compressed = struct.unpack_from("<I", raw, 18)[0]
payload = 30 + name_len
for name, mutate, error in [
    ("crc", lambda b: (struct.pack_into("<I", b, 14, 1), struct.pack_into("<I", b, cd + 16, 1)), "PythonZipPayload"),
    ("local-name", lambda b: b.__setitem__(30, ord("X")), "PythonZipFormat"),
    ("encrypted", lambda b: struct.pack_into("<H", b, cd + 8, 1), "PythonZipFormat"),
    ("descriptor", lambda b: struct.pack_into("<H", b, cd + 8, 8), "PythonZipFormat"),
    ("bad-deflate", lambda b: b.__setitem__(payload, 7), "PythonZipPayload"),
    ("actual-size", lambda b: (struct.pack_into("<I", b, 22, 17), struct.pack_into("<I", b, cd + 24, 17)), "PythonZipPayload"),
    ("zip64", lambda b: struct.pack_into("<H", b, cd + 6, 45), "PythonZipFormat"),
]:
    changed = bytearray(raw)
    mutate(changed)
    emit(name, changed, error)

# Insert one byte after the first compressed stream, keeping all offsets and
# sizes coherent. CRC and actual declared output still match, but this hidden
# trailing byte must not be ignored by the raw inflater integration.
changed = bytearray(raw[:payload + compressed] + b"x" + raw[payload + compressed:])
new_cd = cd + 1
struct.pack_into("<I", changed, 18, compressed + 1)
struct.pack_into("<I", changed, new_cd + 20, compressed + 1)
second_cd = new_cd + 46 + name_len
second_offset = struct.unpack_from("<I", changed, second_cd + 42)[0]
struct.pack_into("<I", changed, second_cd + 42, second_offset + 1)
struct.pack_into("<I", changed, len(changed) - 6, new_cd)
emit("member-trailing", changed, "PythonZipPayload")
emit("archive-trailing", raw + b"hidden", "PythonZipFormat")
emit("archive-prefix", b"hidden" + raw, "PythonZipFormat")
(ROOT / "index.json").write_bytes((json.dumps(fixtures, indent=2) + "\n").encode("utf-8"))
