"""Generate small fixed bootstrap regressions with Python's standard archive libraries."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1] / "src/app/office_component_archive_fixtures"
ROOT.mkdir(exist_ok=True)


def fixture(name, *, path="payload.bin", target="x86_64-windows-msvc", link=False,
            crc=False, pax=False, trailing=b"", trailing_tar=b"", alias=False,
            duplicate_manifest=False, wrong_member_digest=False, directory=False, binary_size=False):
    payload = b"runtime"
    entries = [(path, payload)]
    if alias:
        entries.append((path.upper(), b"second"))
    if duplicate_manifest:
        entries.append(("extra.bin", b"second"))
    manifest_files = [{"path": item, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                      for item, data in entries]
    if wrong_member_digest:
        manifest_files[0]["sha256"] = "0" * 64
    if duplicate_manifest:
        manifest_files[1] = dict(manifest_files[0])
    manifest = json.dumps({"schema": 1, "target": target,
                           "payloadBytes": sum(len(data) for _, data in entries),
                           "files": manifest_files}, separators=(",", ":")).encode("utf-8")
    contents = io.BytesIO()
    with tarfile.open(fileobj=contents, mode="w", format=tarfile.PAX_FORMAT if pax else tarfile.USTAR_FORMAT) as archive:
        if directory:
            header = tarfile.TarInfo("tools")
            header.type = tarfile.DIRTYPE
            archive.addfile(header)
        for item, data in [*entries, ("office-runtime.json", manifest)]:
            header = tarfile.TarInfo(item)
            if pax:
                header.pax_headers = {"comment": "must not be silently consumed"}
            if link and item == path:
                header.type = tarfile.SYMTYPE
                header.linkname = "../outside"
                archive.addfile(header)
            else:
                header.size = len(data)
                archive.addfile(header, io.BytesIO(data))
    tar_bytes = bytearray(contents.getvalue())
    if binary_size:
        tar_bytes[124:136] = b"\x80\x00\x00\x00" + (2**64-1).to_bytes(8, "big")
        tar_bytes[148:156] = b" " * 8
        checksum = sum(tar_bytes[:512])
        tar_bytes[148:156] = f"{checksum:06o}\0 ".encode("ascii")
    compressed = bytearray(gzip.compress(tar_bytes + trailing_tar, mtime=0))
    if crc:
        compressed[-8] ^= 1
    compressed.extend(trailing)
    (ROOT / (name + ".tar.gz")).write_bytes(compressed)
    metadata = {"archive_bytes": len(compressed), "sha256": hashlib.sha256(compressed).hexdigest(),
                "unpacked_bytes": sum(len(data) for _, data in entries) + len(manifest),
                "files": len(entries) + 1, "target": "x86_64-windows-msvc"}
    (ROOT / (name + ".json")).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8", newline="\n")


fixture("valid")
fixture("directory", directory=True, path="tools/payload.bin")
fixture("traversal", path="../escape")
fixture("symlink", link=True)
fixture("pax", pax=True)
fixture("binary-size", binary_size=True)
fixture("crc", crc=True)
fixture("wrong-target", target="aarch64-windows-msvc")
fixture("wrong-member", wrong_member_digest=True)
fixture("duplicate-manifest", duplicate_manifest=True)
fixture("case-collision", alias=True)
fixture("debug", path="payload.PDB")
fixture("trailing", trailing=b"ignored bytes")
fixture("trailing-tar", trailing_tar=b"ignored tar bytes")
