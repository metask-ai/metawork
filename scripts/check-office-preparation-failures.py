"""Opt-in Windows failure qualification; downloads the fixed Python archive once."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

if sys.platform != "win32" or sys.argv[1:] != ["--download"]:
    raise SystemExit("Usage on Windows: python scripts/check-office-preparation-failures.py --download")
repo = Path(__file__).resolve().parents[1]
scratch = Path(tempfile.mkdtemp(prefix="office-negative qualification ", dir=repo / ".zig-cache"))
resources = scratch / "resources"
resources.mkdir()
subprocess.run(["tar.exe", "-xf", str(repo / "src/app/office-skills.tar.gz"), "-C", str(resources)], check=True)
entry = resources / "docx/environment"
offline = dict(os.environ, HTTPS_PROXY="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1", ALL_PROXY="http://127.0.0.1:1")


def command(profile, script, *arguments, network=False):
    values = [entry / script, *arguments]
    quoted = " ".join('"' + str(value) + '"' for value in values)
    result = subprocess.run('cmd.exe /d /s /c "' + quoted + '"',
                            env=dict(os.environ if network else offline, LOCALAPPDATA=str(profile)),
                            capture_output=True, timeout=360)
    assert result.returncode != 0, result.stdout
    return result


def inventory(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


missing = scratch / "missing profile"
assert command(missing, "run.cmd", "python", "unused.py").returncode == 3
assert command(missing, "run.cmd", "node", "unused.cjs").returncode == 3
assert not missing.exists(), "Run downloaded or created an environment"
command(missing, "prepare.cmd", "arbitrary-package")
assert not missing.exists()

# Existing final directories must remain byte-for-byte unchanged, even when bad.
config = (entry / "environment.cmd").read_text()
broken = scratch / "broken profile"
home = broken / "MetaWork/OfficeDependencies"
for language in ("python", "node"):
    identity = re.search(language.upper() + r'_ID=([a-f0-9]+)', config)[1]
    final = home / (language + "-" + identity)
    final.mkdir(parents=True)
    (final / "preserve.txt").write_text("completed but unusable fixture", encoding="utf-8")
before = inventory(home)
for language in ("python", "node"):
    command(broken, "prepare.cmd", language)
assert before == inventory(home)
assert len(list(home.iterdir())) == 2, "Preparation repaired/quarantined an existing directory"

unwritable = scratch / "occupied profile"
(unwritable / "MetaWork").mkdir(parents=True)
(unwritable / "MetaWork/OfficeDependencies").write_text("occupied", encoding="utf-8")
command(unwritable, "prepare.cmd", "python")
assert (unwritable / "MetaWork/OfficeDependencies").read_text() == "occupied"

failed = scratch / "failed profile"
command(failed, "prepare.cmd", "python")
assert not list((failed / "MetaWork/OfficeDependencies").iterdir()), "Failed download left published or staged files"

# Deliberately mismatch the fixed archive digest in an isolated resource copy.
# The archive is downloaded but must never be extracted or executed.
(entry / "environment.cmd").write_text(re.sub(r'PYTHON_SHA=[a-f0-9]{64}', 'PYTHON_SHA=' + '0' * 64, config), encoding="utf-8", newline="\n")
rejected = scratch / "hash profile"
command(rejected, "prepare.cmd", "python", network=True)
assert not list((rejected / "MetaWork/OfficeDependencies").iterdir()), "Hash rejection left extracted or published files"
print("Missing/invalid target, damaged final preservation, occupied destination, download failure and hash rejection passed: " + str(scratch))
