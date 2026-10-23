"""Prepare one fixed private Python directory; never repair an existing one."""
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys
import time


def check(root):
    if "{}.{}.{}".format(*sys.version_info[:3]) != json.loads((Path(__file__).parent / "environment.json").read_text())["python"]["version"]:
        raise RuntimeError("Unexpected private Python version")
    sys.path.insert(0, str(root / "packages"))
    import defusedxml.ElementTree
    import lxml.etree
    import openpyxl
    import PIL.Image
    expected = dict(line.split()[0].split("==") for line in (Path(__file__).parent / "requirements.txt").read_text().splitlines() if line)
    if any(importlib.metadata.version(k) != v for k, v in expected.items()):
        raise RuntimeError("Private Python libraries differ from their lock")


def publish(stage, final):
    for attempt in range(5):
        try:
            stage.rename(final)
            return
        except OSError as failure:
            if final.exists():
                result = subprocess.run([str(final / "tools/python.exe"), "-I", "-B", __file__, "--check", str(final)])
                if result.returncode:
                    raise RuntimeError("Existing private Python environment is unusable") from failure
                # The cmd parent removes our staging tree after this staged
                # interpreter exits; Windows may still hold its executable.
                return
            if getattr(failure, "winerror", None) not in (5, 32, 33) or attempt == 4:
                raise
            time.sleep(0.1 * (attempt + 1))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        root = Path(sys.argv[2])
        check(root)
        print(root)
    else:
        stage, final, resources = map(Path, sys.argv[1:])
        # CLI options fix install effects while pip retains its normal network
        # configuration. Do not print user configuration or credentials.
        subprocess.run([sys.executable, "-I", "-B", "-m", "pip", "--disable-pip-version-check", "install",
                        "--require-hashes", "--only-binary", ":all:", "--no-compile", "--no-user", "--no-cache-dir",
                        "--target", str(stage / "packages"), "-r", str(resources / "requirements.txt")], check=True, timeout=600)
        check(stage)
        publish(stage, final)
        print(final)
