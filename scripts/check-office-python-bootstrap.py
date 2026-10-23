"""Qualify the actual native first stage, with a stdlib fixture/oracle collector.

Collector Python creates negative archives and independently reads the official
ZIP; the candidate is extracted and authenticated entirely by the native probe.
Only an authenticated candidate executes the fixed, isolated smoke command.
This is not a clean-machine test or the complete App installation transaction.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile

if sys.platform != "win32" or len(sys.argv) != 3:
    raise SystemExit("Usage: check-office-python-bootstrap.py <canonical-download-cache> <native-first-stage-probe.exe>")
ROOT = Path(__file__).resolve().parents[1]
DOWNLOADS, PROBE = [Path(arg).resolve(strict=True) for arg in sys.argv[1:]]
SOURCE = json.loads((ROOT / "build_support/office-runtime.windows-x64.sources.json").read_bytes())["bootstrapPython"]
ZIP = DOWNLOADS / SOURCE["url"].rsplit("/", 1)[1]


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


assert ZIP.stat().st_size == SOURCE["bytes"] and digest(ZIP) == SOURCE["sha256"]
cache = ROOT / ".zig-cache/office-python-bootstrap-qualification"
cache.mkdir(parents=True, exist_ok=True)
directory = Path(tempfile.mkdtemp(prefix="原生 Python 路径 ", dir=cache))
probe_sha = digest(PROBE)
collector_sha = digest(Path(__file__))
results = []


def prepare(name, archive, expected_digest, expected_bytes):
    stage = directory / name
    stage.mkdir()
    result = subprocess.run([str(PROBE), str(archive), expected_digest, str(expected_bytes), str(stage)],
                            cwd=directory, capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert result.returncode == 0, result.stderr
    receipt = json.loads(result.stdout)
    results.append({"name": name, "receipt": receipt})
    return stage, receipt


stage, receipt = prepare("verified", ZIP, SOURCE["sha256"], SOURCE["bytes"])
assert receipt["status"] == "authenticated", receipt
with zipfile.ZipFile(ZIP) as archive:
    expected = {entry.filename: (entry.file_size, hashlib.sha256(archive.read(entry)).hexdigest()) for entry in archive.infolist()}
actual = {file.relative_to(stage / "bootstrap").as_posix(): (file.stat().st_size, digest(file))
          for file in (stage / "bootstrap").rglob("*") if file.is_file()}
assert actual == expected
python = stage / "bootstrap/python.exe"
smoke = subprocess.run([str(python), "-I", "-S", "-B", "-c",
                        "import json,sys;print(json.dumps({'executable':sys.executable,'version':'.'.join(map(str,sys.version_info[:3]))}))"],
                       cwd=directory, capture_output=True, text=True, encoding="utf-8", timeout=10)
assert smoke.returncode == 0, smoke.stderr
identity = json.loads(smoke.stdout)
assert Path(identity["executable"]).resolve() == python.resolve() and identity["version"] == SOURCE["version"]
assert {file.relative_to(stage / "bootstrap").as_posix(): (file.stat().st_size, digest(file))
        for file in (stage / "bootstrap").rglob("*") if file.is_file()} == expected

_, wrong_hash = prepare("wrong-hash", ZIP, "1" * 64, SOURCE["bytes"])
assert wrong_hash == {"status": "rejected", "reason": "PythonZipDigest"}
assert not (directory / "wrong-hash/bootstrap").exists()

for name, reason in (("wrong-machine", "InvalidComponentPe"), ("tampered-code", "InvalidAuthenticode")):
    negative = directory / (name + ".zip")
    with zipfile.ZipFile(ZIP) as source, zipfile.ZipFile(negative, "x") as output:
        for info in source.infolist():
            content = source.read(info)
            if info.filename == "python.exe":
                changed = bytearray(content)
                pe = struct.unpack_from("<I", changed, 60)[0]
                if name == "wrong-machine":
                    struct.pack_into("<H", changed, pe + 4, 0xaa64)
                else:
                    optional_size = struct.unpack_from("<H", changed, pe + 20)[0]
                    section = pe + 24 + optional_size
                    assert changed[section:section + 5] == b".text"
                    raw_offset = struct.unpack_from("<I", changed, section + 20)[0]
                    changed[raw_offset + 16] ^= 1  # Authenticode-covered code, never executed.
                content = bytes(changed)
            output.writestr(info, content)
    _, rejected = prepare(name, negative, digest(negative), negative.stat().st_size)
    assert rejected == {"status": "rejected", "reason": reason}, rejected

assert digest(PROBE) == probe_sha, "Probe changed while collecting"
assert digest(Path(__file__)) == collector_sha, "Collector changed while collecting"
evidence = {"schema": 1, "passed": True, "scope": "Native first-stage snapshot/ZIP/PE/WinTrust and authenticated interpreter smoke only; not full App downloads/installation or clean-machine acceptance",
            "directory": str(directory), "sourceSha256": SOURCE["sha256"], "sourceBytes": SOURCE["bytes"],
            "probeSha256": probe_sha, "collectorSha256": collector_sha,
            "files": len(expected), "unpackedBytes": sum(size for size, _ in expected.values()),
            "executedAfterAuthentication": True, "identity": identity, "results": results}
(directory / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
print(json.dumps(evidence))
