"""Prepare one fixed private Python directory; never repair an existing one."""
import importlib.metadata
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parent))
from configuration import current


def valid_directory(root):
    if root.is_symlink() or (hasattr(root, "is_junction") and root.is_junction()) or not root.is_dir():
        raise RuntimeError("Office final path must be a real directory")


def check(root):
    valid_directory(root)
    if current()["target"] != "windows-x86_64" and Path(sys.executable).resolve() != (root / current()["layout"]["pythonExecutable"]).resolve():
        raise RuntimeError("Office Python is not running from its selected environment")
    if "{}.{}.{}".format(*sys.version_info[:3]) != current()["python"]["version"]:
        raise RuntimeError("Unexpected private Python version")
    sys.path.insert(0, str(root / "packages"))
    import defusedxml.ElementTree
    import lxml.etree
    import openpyxl
    import PIL.Image
    expected = dict(line.split()[0].split("==") for line in (Path(__file__).parent / current()["requirements"]).read_text().splitlines() if line)
    if any(importlib.metadata.version(k) != v for k, v in expected.items()):
        raise RuntimeError("Private Python libraries differ from their lock")


def check_final(final, language="python"):
    valid_directory(final)
    config = current()
    executable = final / config["layout"][language + "Executable"]
    args = [str(executable)]
    args += ["-I", "-B", __file__] if language == "python" else [str(Path(__file__).parent / "finish.cjs")]
    subprocess.run(args + ["--check", str(final)], check=True, timeout=60)


def publish(stage, final, language="python"):
    if sys.platform == "darwin":
        from darwin_publish import publish as exclusive_publish
        try:
            exclusive_publish(stage, final)
        except FileExistsError:
            pass
        check_final(final, language)
        return
    for attempt in range(5):
        try:
            stage.rename(final)
            return
        except OSError as failure:
            if final.exists() or final.is_symlink():
                valid_directory(final)
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
    if sys.platform == "darwin":
        from managed_process import interrupted, run as managed_run
        signal.signal(signal.SIGINT, interrupted)
        signal.signal(signal.SIGTERM, interrupted)
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--check":
            root = Path(sys.argv[2])
            check(root)
            print(root)
        elif len(sys.argv) == 5 and sys.argv[1] == "--node":
            if sys.platform != "darwin":
                raise RuntimeError("Node coordinator requires macOS")
            check(Path(sys.executable).resolve().parents[2])
            stage, final, resources = map(Path, sys.argv[2:])
            node = stage / current()["layout"]["nodeExecutable"]
            managed_run([str(node), str(resources / "finish.cjs"), "--install", str(stage), str(resources)], stage)
            publish(stage, final, "node")
            print(final)
        elif len(sys.argv) == 4:
            stage, final, resources = map(Path, sys.argv[1:])
            # Keep package-manager network configuration; fix all install effects.
            command = [sys.executable, "-I", "-B", "-m", "pip", "--disable-pip-version-check", "install",
                       "--require-hashes", "--only-binary", ":all:", "--no-compile", "--no-user", "--no-cache-dir",
                       "--target", str(stage / "packages"), "-r", str(resources / current()["requirements"])]
            if sys.platform == "darwin":
                managed_run(command, stage)
            else:
                subprocess.run(command, check=True, timeout=600)
            check(stage)
            publish(stage, final)
            if current()["target"] == "windows-aarch64":
                check_final(final)
            print(final)
        else:
            raise RuntimeError("Invalid fixed Office preparation invocation")
    except KeyboardInterrupt:
        print("Office preparation cancelled; completed directories were preserved.", file=sys.stderr)
        raise SystemExit(130)
