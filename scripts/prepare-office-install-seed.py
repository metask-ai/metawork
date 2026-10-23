"""Package only authenticated, self-owned adaptation and bootstrap resources.

The caller generates the plan from canonical locks and measured fixed public
archives. This build tool does not authorize a release, download or execution.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys
import uuid

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/app/office_bootstrap"))
import payload
from packages import relative, root_path
from msi import ordinary

MAX_FILES = 512
MAX_BYTES = 8 * 1024**2
MAX_ARCHIVE = 1024**2


def sha(content):
    return hashlib.sha256(content).hexdigest()


def bounded_read(file, limit):
    root_path(file.parent)
    if ordinary(file, stat.S_ISREG).st_size > limit:
        raise ValueError("Seed input exceeds budget")
    with file.open("rb") as source:
        content = source.read(limit + 1)
    if len(content) > limit:
        raise ValueError("Actual seed input exceeds budget")
    return content


def build(component_root, plan_path, output):
    component_root = root_path(component_root)
    plan_bytes = bounded_read(plan_path, 2 * 1024**2)
    plan = json.loads(plan_bytes)
    manifest_bytes = bounded_read(component_root / "office-runtime.json", 8 * 1024**2)
    manifest = json.loads(manifest_bytes)
    if (plan["schema"] != 1 or plan["target"] != "x86_64-windows-msvc" or
            manifest["schema"] != 1 or manifest["target"] != plan["target"] or
            sha(manifest_bytes) != plan["manifestSha256"]):
        raise ValueError("Seed and producer manifest identity differ")
    expected = {entry["path"]: entry for entry in manifest["files"]}
    if len(expected) != len(manifest["files"]):
        raise ValueError("Duplicate component manifest path")
    own = {}
    for name in ("docx", "xlsx", "pptx"):
        base = REPO / "src/product/skill/assets" / name
        for file in payload.tree_files(base):
            if "__pycache__" not in file.parts and file.suffix != ".pyc":
                own["skills/" + name + "/" + file.relative_to(base).as_posix()] = file
    for name in ("office.py", "node.mjs", "document_text.py", "document_preview.py", "pdf_source.py", "static_workbook.py"):
        own["tools/" + name] = REPO / "src/product/skill/office_runtime" / name
    own["tools/office_archive.py"] = REPO / "src/product/control/resources/archive.py"
    own["tools/spreadsheet_checks.py"] = REPO / "src/product/skill/assets/xlsx/scripts/office/formulas.py"
    for name in ("office-runtime.windows-x64.sources.json", "office-python.windows-x64.lock.json", "office-workflows.json"):
        own["sources/" + name] = REPO / "build_support" / name
    own["sources/office-requirements.txt"] = REPO / "scripts/office-requirements.txt"
    # These are build outputs, never vendor payload or path-dependent pip data.
    for name in ("bin/office.exe", "licenses/THIRD-PARTY.txt", "sources/build.json", "sources/office-dependency-layout.json"):
        own[name] = None
    selected = {name for name in expected if name.startswith(("skills/", "tools/", "sources/", "bin/"))}
    if selected != set(own) - {"licenses/THIRD-PARTY.txt"}:
        raise ValueError("Producer self-owned resources differ from the current source set")
    stage = REPO / ".zig-cache/office-components" / ("build-seed-" + str(uuid.uuid4()))
    stage.mkdir()
    total = count = 0

    def put(name, content):
        nonlocal total, count
        relative(name)
        if (any(part.casefold() in ("node_modules", "python-packages", "engine", "node") for part in Path(name).parts) or
                (re.search(r"\.(dll|pyd|whl|msi|cab|exe)$", name, re.I) and name != "component/bin/office.exe")):
            raise ValueError("Vendor runtime is forbidden in the self-owned seed")
        count += 1
        total += len(content)
        if count > MAX_FILES or total > MAX_BYTES or len(content) > 1024**2:
            raise ValueError("Self-owned seed exceeds budget")
        target = stage / relative(name)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as file:
            file.write(content)

    for name, source in sorted(own.items()):
        entry = expected[name]
        content = bounded_read(component_root / relative(name), 1024**2)
        if len(content) != entry["bytes"] or sha(content) != entry["sha256"]:
            raise ValueError("Producer resource changed")
        if source and content != bounded_read(source, 1024**2):
            raise ValueError("Producer contains stale self-owned resources")
        if name == "sources/office-dependency-layout.json" and json.loads(content) != plan["recipe"]:
            raise ValueError("Producer dependency recipe differs from canonical inputs")
        put("component/" + name, content)
    for name in ("msi.py", "packages.py", "payload.py", "assemble.py"):
        put("bootstrap/" + name, bounded_read(REPO / "src/app/office_bootstrap" / name, 1024**2))
    put("bootstrap/office_archive.py", bounded_read(REPO / "src/product/control/resources/archive.py", 1024**2))
    put("bootstrap/plan.json", plan_bytes)
    payload.write_manifest(stage)
    result = payload.write_archive(stage, output, compressed_limit=MAX_ARCHIVE)
    if result["unpackedBytes"] > MAX_BYTES or result["files"] > MAX_FILES:
        output.unlink()
        raise ValueError("Final seed exceeds budget")
    result.update({"scope": "Self-owned installation input only; not a published client release",
                   "clientInstallable": False, "manifestSha256": sha((stage / "office-runtime.json").read_bytes()),
                   "componentManifestSha256": plan["manifestSha256"], "directory": str(stage)})
    output.with_suffix(output.suffix + ".json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("component", type=Path)
    parser.add_argument("plan", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if sys.platform != "win32" or not args.output.is_absolute() or args.output.exists():
        parser.error("Windows and a new absolute seed output are required")
    build(args.component, args.plan, args.output)
