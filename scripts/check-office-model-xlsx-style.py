"""Independent frozen oracle for the targeted stored-style repair workflow.

Run through a prepared private Python entry. This consumes fixed test assertions,
not the model's check specification. Actual receipts/final wording are separate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("candidate", type=Path)
parser.add_argument("report", type=Path)
parser.add_argument("--original", required=True, type=Path)
parser.add_argument("--entry", required=True, type=Path)
args = parser.parse_args()
case = json.loads((ROOT / "tests/fixtures/office/style-repair-acceptance.json").read_text())
original = args.original.resolve(strict=True)
if hashlib.sha256(original.read_bytes()).hexdigest() != case["input_sha256"]:
    raise SystemExit("Frozen original identity differs")
spec = json.loads((ROOT / "tests/fixtures/office" / case["base_oracle"]).read_text())
for check in case["additional_checks"]:
    if check.get("original") == "@input":
        check["original"] = str(original)
    spec["checks"].append(check)
    spec["requirements"].append({"id": check["id"], "source": "Frozen full-range style repair requirement", "checks": [check["id"]]})
entry = args.entry.resolve(strict=True)
prefix = ["/bin/sh", str(entry)] if entry.suffix == ".sh" else [str(entry)]
with tempfile.TemporaryDirectory(prefix="office-style-oracle-") as temporary:
    checks = Path(temporary) / "checks.json"
    checks.write_text(json.dumps(spec), encoding="utf-8")
    result = subprocess.run(prefix + ["python", str(entry.parent.parent / "scripts/verify.py"),
                            str(args.candidate.resolve(strict=True)), str(args.report.resolve()),
                            "--checks", str(checks)], text=True, capture_output=True, timeout=30)
print(result.stdout, end="")
if result.stderr:
    print(result.stderr, end="", file=sys.stderr)
raise SystemExit(result.returncode)
