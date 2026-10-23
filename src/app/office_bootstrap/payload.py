"""Shared deterministic Windows runtime layout and component inventory.

The caller authenticates fixed vendor inputs before calling layout, and owns
the private, fresh tree through process join. No executable is run here. A
bootstrap-generated manifest is usable only when its bytes match the digest
pinned by the main; computing a manifest does not grant installation trust.
"""
import hashlib
import gzip
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from msi import ordinary
from packages import root_path, relative, signature


def copy_file(source, destination, *, replace=False):
    ordinary(source, stat.S_ISREG)
    root_path(source.parent)
    root_path(destination.parent)
    if replace and destination.exists():
        ordinary(destination, stat.S_ISREG)
    with source.open("rb") as incoming, destination.open("wb" if replace else "xb") as output:
        shutil.copyfileobj(incoming, output, 65536)


def tree_entries(root):
    """No recursion through reparse points, including directory junctions."""
    root_path(root)
    entries, seen = [], set()
    pending = [root]
    while pending:
        current = pending.pop()
        for file in current.iterdir():
            name = file.relative_to(root).as_posix()
            relative(name)
            folded = name.casefold()
            if folded in seen or len(seen) >= 60000:
                raise ValueError("Component member collision or budget exceeded")
            seen.add(folded)
            info = file.lstat()
            ordinary(file, stat.S_ISDIR if stat.S_ISDIR(info.st_mode) else stat.S_ISREG)
            entries.append((file, stat.S_ISDIR(info.st_mode)))
            if stat.S_ISDIR(info.st_mode):
                pending.append(file)
    return sorted(entries)


def tree_files(root):
    return [file for file, directory in tree_entries(root) if not directory]


def copy_tree(source, destination):
    entries = tree_entries(source)
    destination.mkdir()
    for file, directory in entries:
        target = destination / file.relative_to(source)
        if directory:
            target.mkdir()
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        copy_file(file, target)


def layout(root, node_zip, font, font_license, sources, archive_helper):
    root_path(root)
    program = root / "engine/program"
    python = root / "python"
    if python.exists() or not (program / "soffice.com").is_file():
        raise ValueError("Layout requires a fresh, read-only extracted Office tree")
    copy_tree(program / sources["libreoffice"]["pythonDirectory"], python)
    # These app-local vendor libraries are also needed on a clean machine.
    for library in sorted((root / "engine/System64").glob("*.dll")):
        copy_file(library, program / library.name, replace=True)
        copy_file(library, python / "bin" / library.name, replace=True)
    for name in ("python313.dll", "python3.dll"):
        copy_file(program / name, python / "bin" / name)
    with (python / "bin/python313._pth").open("x", encoding="ascii") as output:
        output.write("../lib\n")
    node = root / "node"
    node.mkdir()
    limits = archive_helper.Limits(archive_bytes=128 * 1024**2, members=20000,
                                  metadata_bytes=8 * 1024**2, member_bytes=128 * 1024**2,
                                  total_bytes=512 * 1024**2)
    for name in ("node.exe", "LICENSE"):
        data = archive_helper.read_member(node_zip, sources["node"]["archiveRoot"] + "/" + name, limits)
        with (node / name).open("xb") as output:
            output.write(data)
    fonts = root / "engine/share/fonts/truetype"
    fonts.mkdir(parents=True, exist_ok=True)
    for file in sorted((root / "engine/Fonts").iterdir()):
        copy_file(file, fonts / file.name)
    copy_file(font, fonts / "NotoSansCJKsc-Regular.otf")
    licenses = root / "licenses"
    licenses.mkdir()
    copy_file(font_license, licenses / "NotoSansCJK-OFL.txt")


def manifest_bytes(root):
    files, total = [], 0
    for file in tree_files(root):
        name = file.relative_to(root).as_posix()
        if name == "office-runtime.json":
            raise ValueError("Component was already finalized")
        before = ordinary(file, stat.S_ISREG)
        digest = hashlib.sha256()
        size = 0
        with file.open("rb") as source:
            if signature(os.fstat(source.fileno())) != signature(before):
                raise ValueError("Component file changed before reading")
            while chunk := source.read(65536):
                digest.update(chunk)
                size += len(chunk)
                total += len(chunk)
                if size > 512 * 1024**2 or total > 3 * 1024**3:
                    raise ValueError("Actual component byte budget exceeded")
            if signature(os.fstat(source.fileno())) != signature(before):
                raise ValueError("Component file changed while reading")
        if size != before.st_size or signature(ordinary(file, stat.S_ISREG)) != signature(before):
            raise ValueError("Component file changed after reading")
        files.append({"path": name, "bytes": size, "sha256": digest.hexdigest()})
    if not files or len(files) > 50000:
        raise ValueError("Component file budget exceeded")
    manifest = {"schema": 1, "target": "x86_64-windows-msvc", "payloadBytes": total, "files": files}
    # Preserve the Windows producer's schema-1 serialization exactly, including
    # its CRLF terminator. This enables byte equality with existing candidates.
    return (json.dumps(manifest, separators=(",", ":")) + "\r\n").encode("utf-8")


def write_manifest(root, expected_sha256=None):
    content = manifest_bytes(root)
    if expected_sha256 is not None and hashlib.sha256(content).hexdigest() != expected_sha256:
        raise ValueError("Assembled component differs from the main-pinned manifest")
    with (root / "office-runtime.json").open("xb") as output:
        output.write(content)
    return json.loads(content)


def write_archive(root, output, *, compressed_limit=800 * 1024**2):
    entries = tree_entries(root)
    if not (root / "office-runtime.json").is_file():
        raise ValueError("Finalized component manifest is required")
    output.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        with output.open("xb") as file:
            created = True
            with gzip.GzipFile(filename="", fileobj=file, mode="wb", mtime=0, compresslevel=6) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.USTAR_FORMAT) as archive:
                    for file, directory in entries:
                        entry = archive.gettarinfo(str(file), arcname=file.relative_to(root).as_posix())
                        entry.uid = entry.gid = entry.mtime = 0
                        entry.uname = entry.gname = ""
                        entry.mode = 0o755 if directory or file.suffix.lower() in (".exe", ".com") else 0o644
                        if directory:
                            archive.addfile(entry)
                        else:
                            with file.open("rb") as data:
                                archive.addfile(entry, data)
        if output.stat().st_size > compressed_limit:
            raise ValueError("Compressed archive exceeds budget")
        digest = hashlib.sha256()
        with output.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        files = [file for file, directory in entries if not directory]
        return {"schema": 1, "target": "x86_64-windows-msvc", "bytes": output.stat().st_size,
                "sha256": digest.hexdigest(), "unpackedBytes": sum(file.stat().st_size for file in files),
                "files": len(files), "format": "tar.gz", "tarFormat": "ustar"}
    except BaseException:
        if created:
            output.unlink(missing_ok=True)
        raise
