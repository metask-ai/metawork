"""Verify a producer's actual tar.gz payload against its complete file manifest.

Streams all bytes without extraction. This is a producer check, not the Host
installer or a substitute for release signatures/clean-machine qualification.
"""
import gzip
import hashlib
import json
from pathlib import PurePosixPath
import sys
import tarfile
import unicodedata


def verify(filename):
    observed = {}
    paths = set()
    manifest = None
    total = 0
    members = 0
    with gzip.open(filename, "rb") as compressed:
        with tarfile.open(fileobj=compressed, mode="r|") as archive:
            for item in archive:
                members += 1
                name = item.name
                path = PurePosixPath(name)
                if (members > 60000 or len(name.encode("utf-8")) > 512 or path.is_absolute()
                        or any(part in ("", ".", "..") or part != part.rstrip(" .")
                               or any(ord(c) < 32 or c in '\\:<>"|?*' for c in part) for part in name.split("/"))):
                    raise ValueError("Unsafe component path or member budget")
                key = unicodedata.normalize("NFC", name).casefold()
                if key in paths or item.pax_headers or item.offset_data - item.offset != 512:
                    raise ValueError("Duplicate path or non-USTAR component metadata")
                paths.add(key)
                if item.isdir():
                    if item.size:
                        raise ValueError("Component directory contains data")
                    continue
                if not item.isfile() or item.size > 512 * 1024**2:
                    raise ValueError("Component links, special files or oversized member")
                total += item.size
                if total > 3 * 1024**3 or path.suffix.lower() in (".pyc", ".pdb"):
                    raise ValueError("Component release size or mutable/debug resource violation")
                source = archive.extractfile(item)
                digest = hashlib.sha256()
                size = 0
                contents = bytearray()
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
                    size += len(chunk)
                    if name == "office-runtime.json":
                        contents.extend(chunk)
                        if len(contents) > 8 * 1024 * 1024:
                            raise ValueError("Component manifest byte budget exceeded")
                if size != item.size:
                    raise ValueError("Truncated component member")
                if name == "office-runtime.json":
                    manifest = json.loads(contents)
                else:
                    observed[name] = {"bytes": size, "sha256": digest.hexdigest()}
            # Read through tar's own buffered stream, then the gzip footer/CRC;
            # discarding its lookahead could hide nonzero trailing payload.
            padding = archive.fileobj.read(10241)
            if len(padding) > 10240 or any(padding):
                raise ValueError("Unexpected data after component tar end")
    if manifest is None or manifest["schema"] != 1 or manifest["target"] != "x86_64-windows-msvc":
        raise ValueError("Missing or unsupported Office component manifest")
    expected = {entry["path"]: {"bytes": entry["bytes"], "sha256": entry["sha256"]}
                for entry in manifest["files"]}
    if len(expected) != len(manifest["files"]) or expected != observed:
        raise ValueError("Component file manifest differs from the actual archive bytes")
    if manifest["payloadBytes"] != sum(item["bytes"] for item in observed.values()):
        raise ValueError("Component payload byte count differs")
    return {"files": len(observed) + 1, "unpackedBytes": total}


if __name__ == "__main__":
    print(json.dumps(verify(sys.argv[1])), flush=True)
