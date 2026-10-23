"""Bounded, deterministic vendoring of already pinned Office dependencies.

Used by the producer and intended for the authenticated bootstrap subprocess.
No package manager, dependency resolution, installation hooks or package imports
run here. Wheels retain their original code, RECORD, metadata and data/scripts;
entry-point wrappers and pip's path-dependent installation records are not made.
The caller owns the private staging tree and must verify the final fixed whole
component inventory before executing it. This is not client install authority.
"""
import argparse
import base64
import csv
from email.parser import BytesParser
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile
import tempfile
import types
from dataclasses import dataclass

# -I excludes the script directory. Only the authenticated bootstrap's own
# sibling module is added; wheel contents are never put on the import path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from msi import component, ordinary


@dataclass(frozen=True)
class Limits:
    sources: int = 64
    compressed_bytes: int = 256 * 1024**2
    member_bytes: int = 128 * 1024**2
    expanded_bytes: int = 512 * 1024**2
    metadata_bytes: int = 8 * 1024**2
    members: int = 20000


def relative(value):
    if (not isinstance(value, str) or not value or value.startswith("/") or
            "\\" in value or len(value.encode("utf-8")) > 1024):
        raise ValueError("Unsafe dependency relative path")
    parts = value.split("/")
    if len(parts) > 32:
        raise ValueError("Dependency path exceeds depth budget")
    for part in parts:
        component(part)
    return Path(*parts)


def root_path(path):
    path = Path(os.path.abspath(path))
    for parent in reversed((path, *path.parents)):
        ordinary(parent, stat.S_ISDIR)
    return path


def signature(info):
    # On current Windows Python, path-stat's deprecated ctime and fd-stat's
    # ctime can describe different clocks. Birth time is the common identity;
    # the copied bytes still must match the fixed cryptographic digest.
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, getattr(info, "st_birthtime_ns", None)


def file_digest(path, algorithm="sha256"):
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class Budget:
    def __init__(self, limits):
        self.limits = limits
        self.compressed = self.expanded = self.members = self.metadata = 0
        self.decoded = self.archive_members = 0
        self.names = {}

    def put(self, source, destination, name):
        path = relative(name)
        key = path.as_posix().casefold()
        for index in range(1, len(path.parts) + 1):
            prefix = Path(*path.parts[:index]).as_posix()
            folded = prefix.casefold()
            if folded in self.names and self.names[folded] != (prefix, "directory"):
                raise ValueError("Dependency path collision")
            if index < len(path.parts):
                self.names[folded] = (prefix, "directory")
        if key in self.names:
            raise ValueError("Duplicate dependency file")
        self.names[key] = (path.as_posix(), "file")
        self.members += 1
        if self.members > self.limits.members:
            raise ValueError("Dependency member budget exceeded")
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        # This private tree is created by us, and archives cannot create links.
        root_path(target.parent)
        size = 0
        with target.open("xb") as output:
            while chunk := source.read(64 * 1024):
                size += len(chunk)
                self.expanded += len(chunk)
                if size > self.limits.member_bytes or self.expanded > self.limits.expanded_bytes:
                    raise ValueError("Actual dependency byte budget exceeded")
                output.write(chunk)

    def snapshot(self, downloads, entry, target):
        algorithm, digest = entry["algorithm"], entry["digest"]
        if (algorithm not in ("sha256", "sha512") or
                not re.fullmatch(r"[a-f0-9]{%d}" % (64 if algorithm == "sha256" else 128), digest)):
            raise ValueError("Invalid dependency digest")
        source_path = downloads / relative(entry["source"])
        root_path(source_path.parent)
        before = ordinary(source_path, stat.S_ISREG)
        if before.st_size <= 0 or self.compressed + before.st_size > self.limits.compressed_bytes:
            raise ValueError("Dependency compressed-byte budget exceeded")
        actual = hashlib.new(algorithm)
        copied = 0
        with source_path.open("rb") as source, target.open("xb") as output:
            if signature(os.fstat(source.fileno())) != signature(before):
                raise ValueError("Dependency source changed")
            while chunk := source.read(64 * 1024):
                copied += len(chunk)
                if copied > before.st_size:
                    raise ValueError("Dependency source grew")
                actual.update(chunk)
                output.write(chunk)
            if signature(os.fstat(source.fileno())) != signature(before):
                raise ValueError("Dependency source changed while copying")
        if (signature(ordinary(source_path, stat.S_ISREG)) != signature(before) or
                copied != before.st_size or actual.hexdigest() != digest):
            raise ValueError("Dependency source identity mismatch")
        self.compressed += copied


def load_archive_helper(path, expected):
    root_path(path.parent)
    if ordinary(path, stat.S_ISREG).st_size > 64 * 1024:
        raise ValueError("Archive helper exceeds budget")
    content = path.read_bytes()
    if hashlib.sha256(content).hexdigest() != expected:
        raise ValueError("Archive helper differs from the generated recipe")
    # Execute exactly the authenticated project source, not an importlib bytecode
    # cache or a package-supplied installation hook.
    module = types.ModuleType("office_bootstrap_archive")
    module.__file__ = str(path)
    sys.modules[module.__name__] = module
    exec(compile(content, str(path), "exec"), module.__dict__)
    return module


def verify_wheel(root, entry, limits):
    metadata = list(root.glob("*.dist-info/METADATA"))
    if len(metadata) != 1 or metadata[0].stat().st_size > limits.metadata_bytes:
        raise ValueError("Wheel metadata identity is missing or too large")
    headers = BytesParser().parsebytes(metadata[0].read_bytes(), headersonly=True)
    normalize = lambda value: re.sub(r"[-_.]+", "-", value).lower()
    if (normalize(headers.get("Name", "")) != normalize(entry["name"]) or
            headers.get("Version") != entry["version"]):
        raise ValueError("Wheel name or version mismatch")
    records = metadata[0].with_name("RECORD")
    if not records.is_file() or records.stat().st_size > limits.metadata_bytes:
        raise ValueError("Wheel RECORD is missing or too large")
    names = set()
    with records.open("r", encoding="utf-8", newline="") as source:
        for row in csv.reader(source):
            if len(row) != 3:
                raise ValueError("Malformed wheel RECORD")
            name, digest, size = row
            path = relative(name)
            if name in names:
                raise ValueError("Duplicate wheel RECORD member")
            names.add(name)
            file = root / path
            ordinary(file, stat.S_ISREG)
            if file == records:
                if digest or size:
                    raise ValueError("Wheel RECORD must not hash itself")
                continue
            if not digest.startswith("sha256=") or not re.fullmatch(r"0|[1-9][0-9]*", size):
                raise ValueError("Unsupported wheel RECORD identity")
            expected = base64.urlsafe_b64encode(bytes.fromhex(file_digest(file))).rstrip(b"=").decode("ascii")
            if digest != "sha256=" + expected or file.stat().st_size != int(size):
                raise ValueError("Wheel RECORD content mismatch")
    actual = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()}
    if names != actual:
        raise ValueError("Wheel RECORD does not cover its complete contents")
    for path in root.glob("*.data/*"):
        if path.name != "scripts":
            raise ValueError("Wheel needs an unsupported data relocation")
    return actual


def extract_wheel(source, destination, entry, scratch, helper, budget):
    limits = budget.limits
    extracted = scratch / "wheel"
    result = helper.safe_extract(source, extracted, helper.Limits(
        archive_bytes=limits.compressed_bytes, metadata_bytes=limits.metadata_bytes,
        members=limits.members - budget.archive_members, member_bytes=limits.member_bytes,
        total_bytes=min(limits.expanded_bytes - budget.expanded, limits.expanded_bytes - budget.decoded)), workspace=scratch)
    budget.archive_members += result["members"]
    budget.decoded += result["bytes"]
    for name in sorted(verify_wheel(extracted, entry, limits)):
        with (extracted / relative(name)).open("rb") as content:
            budget.put(content, destination, "python-packages/" + name)
    shutil.rmtree(extracted)  # Solely our successfully extracted, link-free tree.


class BoundedReader:
    def __init__(self, source, budget):
        self.source, self.budget = source, budget

    def read(self, size=-1):
        limit = self.budget.limits.expanded_bytes - self.budget.decoded + 1
        data = self.source.read(limit if size < 0 else min(size, limit))
        self.budget.decoded += len(data)
        if self.budget.decoded > self.budget.limits.expanded_bytes:
            raise ValueError("Actual npm tar stream exceeds byte budget")
        return data


def extract_npm(source, destination, entry, budget):
    limits = budget.limits
    if not re.fullmatch(r"node_modules/(?:@[^/]+/)?[^/]+(?:/node_modules/(?:@[^/]+/)?[^/]+)*", entry["location"]):
        raise ValueError("Invalid npm package placement")
    relative(entry["location"])
    metadata_entries = 0

    class BoundedInfo(tarfile.TarInfo):
        @classmethod
        def frombuf(cls, buffer, encoding, errors):
            nonlocal metadata_entries
            value = super().frombuf(buffer, encoding, errors)
            budget.archive_members += 1
            if budget.archive_members > limits.members:
                raise ValueError("Aggregate dependency archive-member budget exceeded")
            budget.metadata += 512
            if value.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                metadata_entries += 1
                if value.size > 64 * 1024 or metadata_entries > 128:
                    raise ValueError("npm tar metadata budget exceeded")
                budget.metadata += (value.size + 511) // 512 * 512
            if budget.metadata > limits.metadata_bytes:
                raise ValueError("Aggregate npm metadata budget exceeded")
            return value

    seen = set()
    archive_root = None
    with source.open("rb") as raw, gzip.GzipFile(fileobj=raw) as decompressed:
        bounded = BoundedReader(decompressed, budget)
        with tarfile.open(fileobj=bounded, mode="r|", tarinfo=BoundedInfo, bufsize=512) as archive:
            for member in archive:
                name = member.name.rstrip("/")
                parts = relative(name).parts
                if archive_root is None:
                    archive_root = parts[0]
                if parts[0] != archive_root:
                    raise ValueError("npm archive has multiple top-level roots")
                if len(parts) == 1:
                    if not member.isdir() or member.size:
                        raise ValueError("npm root must be a directory")
                    continue
                path = Path(*parts[1:])
                key = path.as_posix().casefold()
                if key in seen or "node_modules" in [part.casefold() for part in path.parts]:
                    raise ValueError("Duplicate or bundled npm dependency")
                seen.add(key)
                if member.isdir():
                    if member.size:
                        raise ValueError("npm directory contains data")
                    continue
                if not member.isreg() or member.size < 0 or member.size > limits.member_bytes:
                    raise ValueError("npm link, special file or member limit")
                with archive.extractfile(member) as content:
                    budget.put(content, destination, "authoring/" + entry["location"] + "/" + path.as_posix())
        # Consume and authenticate the gzip trailer and bound trailing streams.
        while tail := bounded.read(64 * 1024):
            if any(tail):
                raise ValueError("Unexpected nonzero npm tar trailing data")
    package_json = destination / "authoring" / entry["location"] / "package.json"
    if not package_json.is_file() or package_json.stat().st_size > limits.metadata_bytes:
        raise ValueError("npm package metadata missing or too large")
    metadata = json.loads(package_json.read_text(encoding="utf-8"))
    if metadata.get("name") != entry["name"] or metadata.get("version") != entry["version"]:
        raise ValueError("npm package identity mismatch")


def assemble(recipe, downloads, destination, helper_path, limits=Limits()):
    if recipe.get("schema") != 1 or recipe.get("target") != "x86_64-windows-msvc":
        raise ValueError("Unsupported Office dependency recipe")
    entries = [*recipe["python"], *recipe["javascript"]]
    if not entries or len(entries) > limits.sources:
        raise ValueError("Dependency source count exceeded")
    downloads, destination = root_path(downloads), root_path(destination)
    if any((destination / name).exists() for name in ("python-packages", "authoring")):
        raise ValueError("Dependency output must be fresh")
    helper = load_archive_helper(Path(helper_path), recipe["archiveHelperSha256"])
    budget = Budget(limits)
    with tempfile.TemporaryDirectory(prefix=".packages-", dir=destination) as temporary:
        scratch = Path(temporary)
        for index, entry in enumerate(entries):
            snapshot = scratch / (str(index) + ".archive")
            budget.snapshot(downloads, entry, snapshot)
            if index < len(recipe["python"]):
                extract_wheel(snapshot, destination, entry, scratch, helper, budget)
            else:
                extract_npm(snapshot, destination, entry, budget)
            snapshot.unlink()
    authoring = destination / "authoring"
    authoring.mkdir(exist_ok=True)
    for name, value in (("package.json", recipe["authoring"]["manifest"]), ("package-lock.json", recipe["authoring"]["lock"])):
        content = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        budget.put(io.BytesIO(content), destination, "authoring/" + name)
    return {"files": budget.members, "bytes": budget.expanded, "sourceBytes": budget.compressed}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("downloads", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--archive-helper", required=True, type=Path)
    args = parser.parse_args()
    if os.name != "nt" or ordinary(args.recipe, stat.S_ISREG).st_size > 2 * 1024**2:
        parser.error("Windows and a bounded generated recipe are required")
    recipe = json.loads(args.recipe.read_text(encoding="utf-8"))
    print(json.dumps(assemble(recipe, args.downloads, args.destination, args.archive_helper)), flush=True)
