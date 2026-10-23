"""Deterministic seed for Store tests; its fake Python blob is never executed."""
import gzip
import hashlib
import io
import json
import tarfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    fixtures = root / "src/app/office_component_archive_fixtures"
    metadata = json.loads((fixtures / "valid.json").read_bytes())
    identity = dict(archiveSha256=metadata["sha256"],
                    manifestSha256=hashlib.sha256((fixtures / "valid.manifest.json").read_bytes()).hexdigest(),
                    archiveBytes=metadata["archive_bytes"], unpackedBytes=metadata["unpacked_bytes"], files=metadata["files"])
    plan = dict(schema=1, target=metadata["target"], manifestSha256=identity["manifestSha256"], downloads=[
        dict(name="bootstrapPython", path="runtime.tar.gz", url="https://example.invalid/test-blob", bytes=metadata["archive_bytes"],
             algorithm="sha256", digest=metadata["sha256"])])
    write(fixtures, metadata, identity, plan, "install")
    blob = (fixtures / "valid.tar.gz").read_bytes()
    plan["downloads"].append(dict(name="sha512Dependency", path="dependencies/blob.tar.gz", url="https://example.invalid/sha512-blob",
        bytes=len(blob), algorithm="sha512", digest=hashlib.sha512(blob).hexdigest()))
    write(fixtures, metadata, identity, plan, "install-sha512")


def write(fixtures, metadata, identity, plan, name):
    data = json.dumps(plan, separators=(",", ":")).encode()
    manifest = json.dumps(dict(schema=1, target=metadata["target"], payloadBytes=len(data), files=[
        dict(path="bootstrap/plan.json", bytes=len(data), sha256=hashlib.sha256(data).hexdigest())]), separators=(",", ":")).encode()
    content = io.BytesIO()
    with tarfile.open(fileobj=content, mode="w", format=tarfile.USTAR_FORMAT) as output:
        directory = tarfile.TarInfo("bootstrap/")
        directory.type = tarfile.DIRTYPE
        directory.mode = 0o755
        output.addfile(directory)
        for member_name, value in [("bootstrap/plan.json", data), ("office-runtime.json", manifest)]:
            entry = tarfile.TarInfo(member_name)
            entry.size = len(value)
            entry.mode = 0o644
            output.addfile(entry, io.BytesIO(value))
    archive = gzip.compress(content.getvalue(), mtime=0)
    seed = dict(archiveSha256=hashlib.sha256(archive).hexdigest(), manifestSha256=hashlib.sha256(manifest).hexdigest(),
                archiveBytes=len(archive), unpackedBytes=len(data)+len(manifest), files=2)
    (fixtures / f"{name}-seed.tar.gz").write_bytes(archive)
    (fixtures / f"{name}-input.json").write_bytes((json.dumps(dict(schema=2, protocolRevision=1, target=metadata["target"], seed=seed,
        release=dict(**identity, downloadBytes=sum(entry["bytes"] for entry in plan["downloads"])), retained=[]), indent=2)+"\n").encode())


if __name__ == "__main__":
    main()
