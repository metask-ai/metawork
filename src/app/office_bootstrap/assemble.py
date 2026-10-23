"""Offline Office assembly, run only after Host authenticates the whole seed.

The parent owns this isolated subprocess and staging lifetime. It must pin both
digests passed here, authenticate the temporary interpreter before starting it,
then independently verify final bytes and signatures before executing a runtime
or activating a version. This script does not download, execute or activate one.
"""
import argparse
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msi
import packages
import payload


def read_bounded(path, maximum):
    packages.root_path(path.parent)
    if msi.ordinary(path, stat.S_ISREG).st_size > maximum:
        raise ValueError("Bootstrap metadata exceeds budget")
    with path.open("rb") as source:
        content = source.read(maximum + 1)
    if len(content) > maximum:
        raise ValueError("Actual bootstrap metadata exceeds budget")
    return content


def verify_seed(seed, expected_sha256):
    packages.root_path(seed)
    content = read_bounded(seed / "office-runtime.json", 512 * 1024)
    if hashlib.sha256(content).hexdigest() != expected_sha256:
        raise ValueError("Seed manifest differs from main-pinned identity")
    manifest = json.loads(content)
    if manifest["schema"] != 1 or manifest["target"] != "x86_64-windows-msvc" or len(manifest["files"]) > 512:
        raise ValueError("Invalid seed manifest")
    expected = {entry["path"]: (entry["bytes"], entry["sha256"]) for entry in manifest["files"]}
    if len(expected) != len(manifest["files"]):
        raise ValueError("Duplicate seed member")
    actual, total = {}, len(content)
    for file in payload.tree_files(seed):
        name = file.relative_to(seed).as_posix()
        if name == "office-runtime.json":
            continue
        data = read_bounded(file, 1024**2)
        actual[name] = (len(data), hashlib.sha256(data).hexdigest())
        total += len(data)
        if len(actual) > 512 or total > 8 * 1024**2:
            raise ValueError("Actual seed exceeds budget")
    if actual != expected or manifest["payloadBytes"] != total - len(content):
        raise ValueError("Seed resources differ from authenticated manifest")
    return manifest


def assemble(seed, downloads, destination, manifest_sha256, seed_sha256):
    if not all(re.fullmatch(r"[a-f0-9]{64}", value) for value in (manifest_sha256, seed_sha256)):
        raise ValueError("Fixed bootstrap digest required")
    verify_seed(seed, seed_sha256)
    plan = json.loads(read_bounded(seed / "bootstrap/plan.json", 2 * 1024**2))
    if plan["schema"] != 1 or plan["target"] != "x86_64-windows-msvc" or plan["manifestSha256"] != manifest_sha256:
        raise ValueError("Bootstrap plan differs from main-pinned component")
    if not destination.is_absolute() or destination.exists():
        raise ValueError("Fresh absolute component output is required")
    packages.root_path(destination.parent)
    downloads = packages.root_path(downloads)
    entries = plan["downloads"]
    paths = [entry["path"].casefold() for entry in entries]
    names = [entry["name"] for entry in entries]
    if not entries or len(entries) > 64 or len(set(paths)) != len(paths) or len(set(names)) != len(names):
        raise ValueError("Duplicate or excessive bootstrap source")
    sources = plan["sources"]
    vendors = {entry["name"]: entry for entry in entries if not entry["name"].startswith(("python:", "javascript:"))}
    if set(vendors) != {"libreoffice", "node", "font", "fontLicense", "bootstrapPython"}:
        raise ValueError("Unknown bootstrap vendor layout")
    recipe = plan["recipe"]
    helper_path = seed / "bootstrap/office_archive.py"
    helper = packages.load_archive_helper(helper_path, recipe["archiveHelperSha256"])
    with tempfile.TemporaryDirectory(prefix=".assembly-", dir=destination.parent) as temporary:
        scratch = Path(temporary)
        snapshots = scratch / "downloads"
        snapshots.mkdir()
        budget = packages.Budget(replace(packages.Limits(), compressed_bytes=800 * 1024**2))
        for entry in entries:
            if not isinstance(entry["bytes"], int) or not 0 < entry["bytes"] <= 512 * 1024**2:
                raise ValueError("Bootstrap source size exceeds budget")
            source = downloads / packages.relative(entry["path"])
            if msi.ordinary(source, stat.S_ISREG).st_size != entry["bytes"]:
                raise ValueError("Public source byte count differs")
            target = snapshots / packages.relative(entry["path"])
            target.parent.mkdir(parents=True, exist_ok=True)
            budget.snapshot(downloads, {**entry, "source": entry["path"]}, target)
        destination.mkdir()
        msi_scratch = scratch / "msi"
        msi_scratch.mkdir()
        msi_entry = vendors["libreoffice"]
        msi.extract(snapshots / packages.relative(msi_entry["path"]), destination / "engine", msi_scratch,
                    msi_entry["bytes"], msi_entry["digest"], sources["libreoffice"]["excludedFileIds"])
        payload.layout(destination, snapshots / packages.relative(vendors["node"]["path"]),
                       snapshots / packages.relative(vendors["font"]["path"]),
                       snapshots / packages.relative(vendors["fontLicense"]["path"]), sources, helper)
        packages.assemble(recipe, snapshots, destination, helper_path)
        own = seed / "component"
        for file in payload.tree_files(own):
            target = destination / file.relative_to(own)
            target.parent.mkdir(parents=True, exist_ok=True)
            payload.copy_file(file, target)
        manifest = payload.write_manifest(destination, manifest_sha256)
    return {"status": "success", "manifestSha256": manifest_sha256, "files": len(manifest["files"]) + 1,
            "unpackedBytes": manifest["payloadBytes"] + (destination / "office-runtime.json").stat().st_size}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seed", type=Path)
    parser.add_argument("downloads", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("component_manifest_sha256")
    parser.add_argument("seed_manifest_sha256")
    parser.add_argument("--host-job", required=True)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required")
    from host_job import join
    join(args.host_job)
    print(json.dumps(assemble(args.seed, args.downloads, args.destination,
                              args.component_manifest_sha256, args.seed_manifest_sha256)), flush=True)
