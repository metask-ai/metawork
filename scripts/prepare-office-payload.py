"""Windows component producer mechanics; not an installed document command.

The calling producer verifies fixed source digests before this script consumes
them. Build inputs and an explicit fresh output tree are mandatory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/app/office_bootstrap"))
import payload
from packages import load_archive_helper


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def layout(root, node_zip, font, font_license):
    source = json.loads((REPO / "build_support/office-runtime.windows-x64.sources.json").read_text(encoding="utf-8"))
    helper_path = REPO / "src/product/control/resources/archive.py"
    helper = load_archive_helper(helper_path, digest(helper_path))
    payload.layout(root, node_zip, font, font_license, source, helper)
    licenses = root / "licenses"
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
    for name in ("office.py", "node.mjs", "document_text.py", "document_preview.py", "pdf_source.py", "static_workbook.py"):
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
    # Builder caches and debug symbols are not immutable release resources.
    for file in root.rglob("*.pyc"):
        file.unlink()
    for directory in sorted(root.rglob("__pycache__"), reverse=True):
        directory.rmdir()
    (root / "bin/office.pdb").unlink(missing_ok=True)
    payload.write_manifest(root)
    result = payload.write_archive(root, output)
    output.with_suffix(output.suffix + ".json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result), flush=True)



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
