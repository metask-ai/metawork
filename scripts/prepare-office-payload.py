"""Windows component producer mechanics; not an installed document command.

The calling producer verifies fixed source digests before this script consumes
them. Build inputs and an explicit fresh output tree are mandatory.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import stat
import tarfile
import zipfile

REPO = Path(__file__).resolve().parents[1]


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def layout(root, node_zip, font, font_license):
    source = json.loads((REPO / "build_support/office-runtime.windows-x64.sources.json").read_text(encoding="utf-8"))
    program = root / "engine/program"
    python = root / "python"
    if python.exists() or not (program / "soffice.com").is_file():
        raise ValueError("Layout requires a fresh, read-only extracted Office tree")
    shutil.copytree(program / source["libreoffice"]["pythonDirectory"], python)
    # The MSI's app-local Microsoft runtime is required even on machines which
    # have never installed Office or the VC runtime globally.
    for library in (root / "engine/System64").glob("*.dll"):
        shutil.copyfile(library, program / library.name)
        shutil.copyfile(library, python / "bin" / library.name)
    for name in ("python313.dll", "python3.dll"):
        shutil.copyfile(program / name, python / "bin" / name)
    (python / "bin/python313._pth").write_text("../lib\n", encoding="ascii")
    node = root / "node"
    node.mkdir()
    with zipfile.ZipFile(node_zip) as archive:
        for name in ("node.exe", "LICENSE"):
            data = archive.read(source["node"]["archiveRoot"] + "/" + name)
            (node / name).write_bytes(data)
    fonts = root / "engine/share/fonts/truetype"
    fonts.mkdir(parents=True, exist_ok=True)
    for file in (root / "engine/Fonts").iterdir():
        if not file.is_file():
            raise ValueError("Unexpected vendor font directory")
        shutil.copyfile(file, fonts / file.name)
    shutil.copyfile(font, fonts / "NotoSansCJKsc-Regular.otf")
    licenses = root / "licenses"
    licenses.mkdir()
    shutil.copyfile(font_license, licenses / "NotoSansCJK-OFL.txt")
    (licenses / "THIRD-PARTY.txt").write_text(
        "MetaWork Office component\n\n"
        "LibreOffice and its bundled Python and fonts: engine/license.txt and engine/LICENSE.html.\n"
        "Corresponding LibreOffice source: https://download.documentfoundation.org/libreoffice/src/26.8.1/\n"
        "Node.js: node/LICENSE.\n"
        "Noto Sans CJK SC: NotoSansCJK-OFL.txt (SIL Open Font License 1.1).\n"
        "Python packages: python-packages/*dist-info and their bundled license files.\n"
        "JavaScript packages: authoring/node_modules/*/LICENSE and package metadata.\n"
        "Exact producer sources are included in sources/.\n", encoding="utf-8")
    tools = root / "tools"
    tools.mkdir()
    for name in ("office.py", "node.mjs", "document_text.py", "document_preview.py"):
        shutil.copyfile(REPO / "src/product/skill/office_runtime" / name, tools / name)
    shutil.copyfile(REPO / "src/product/control/resources/archive.py", tools / "office_archive.py")
    shutil.copyfile(REPO / "src/product/skill/assets/xlsx/scripts/office/formulas.py", tools / "spreadsheet_checks.py")
    skills = root / "skills"
    skills.mkdir()
    for name in ("docx", "xlsx", "pptx"):
        shutil.copytree(REPO / "src/product/skill/assets" / name, skills / name,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    sources = root / "sources"
    sources.mkdir()
    for name in ("office-runtime.windows-x64.sources.json", "office-python.windows-x64.lock.json",
                 "office-workflows.json"):
        shutil.copyfile(REPO / "build_support" / name, sources / name)
    shutil.copyfile(REPO / "scripts/office-requirements.txt", sources / "office-requirements.txt")
    # Administrative extraction also copies the installer. It is a producer
    # input, not a second installed payload inside the component.
    for file in (root / "engine").glob("*.msi"):
        file.unlink()
    for file in root.rglob("*.pyc"):
        file.unlink()
    for directory in sorted(root.rglob("__pycache__"), reverse=True):
        directory.rmdir()


def package(root, output):
    if output.exists():
        raise ValueError("Component archive must not already exist")
    if root.parent != (REPO / ".zig-cache/office-components").resolve() or not root.name.startswith("build-"):
        raise ValueError("Finalization only owns a managed component producer staging directory")
    # Interpreter startup during installation may create bytecode despite pip's
    # --no-compile. Mutable caches and build debug symbols aren't release files.
    for file in root.rglob("*.pyc"):
        file.unlink()
    for directory in sorted(root.rglob("__pycache__"), reverse=True):
        directory.rmdir()
    (root / "bin/office.pdb").unlink(missing_ok=True)
    files = []
    total = 0
    for file in sorted(root.rglob("*")):
        info = file.lstat()
        if file.is_symlink() or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise ValueError("Windows component contains a link or special file")
        if file.is_file():
            relative = file.relative_to(root).as_posix()
            if relative == "office-runtime.json":
                raise ValueError("Component was already finalized")
            total += info.st_size
            files.append({"path": relative, "bytes": info.st_size, "sha256": digest(file)})
    if len(files) > 50000 or total > 3 * 1024**3:
        raise ValueError("Office component release budget exceeded")
    manifest = {"schema": 1, "target": "x86_64-windows-msvc", "payloadBytes": total,
                "files": files}
    (root / "office-runtime.json").write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with output.open("xb") as file, gzip.GzipFile(filename="", fileobj=file, mode="wb", mtime=0, compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.USTAR_FORMAT) as archive:
                for file in sorted(root.rglob("*")):
                    entry = archive.gettarinfo(str(file), arcname=file.relative_to(root).as_posix())
                    entry.uid = entry.gid = entry.mtime = 0
                    entry.uname = entry.gname = ""
                    entry.mode = 0o755 if file.is_dir() or file.suffix.lower() in (".exe", ".com") else 0o644
                    if file.is_file():
                        with file.open("rb") as data:
                            archive.addfile(entry, data)
                    else:
                        archive.addfile(entry)
        result = {"schema": 1, "target": manifest["target"], "bytes": output.stat().st_size,
                  "sha256": digest(output), "unpackedBytes": sum(p.stat().st_size for p in root.rglob("*") if p.is_file()),
                  "files": len(files) + 1, "format": "tar.gz", "tarFormat": "ustar"}
        output.with_suffix(output.suffix + ".json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result), flush=True)
    except BaseException:
        output.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("layout")
    prepare.add_argument("root", type=Path)
    prepare.add_argument("node_zip", type=Path)
    prepare.add_argument("font", type=Path)
    prepare.add_argument("font_license", type=Path)
    finalize = commands.add_parser("package")
    finalize.add_argument("root", type=Path)
    finalize.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "layout":
        layout(args.root.resolve(strict=True), args.node_zip, args.font, args.font_license)
    else:
        package(args.root.resolve(strict=True), args.output.resolve())
