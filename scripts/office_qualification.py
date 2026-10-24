"""Native target, isolated profile and bounded invocation for Office probes."""
import os
from pathlib import Path
import platform
import subprocess
import sys

TARGETS = ("windows-x86_64", "windows-aarch64", "macos-aarch64", "macos-x86_64")
PREPARE_TIMEOUT = 1800 + 600 + 2 * 60 + 180


def native_target():
    system = {"win32": "windows", "darwin": "macos"}.get(sys.platform)
    arch = {"AMD64": "x86_64", "x86_64": "x86_64", "ARM64": "aarch64", "arm64": "aarch64"}.get(platform.machine())
    if sys.platform == "win32" and os.environ.get("PROCESSOR_ARCHITEW6432", "").upper() == "ARM64":
        arch = "aarch64"
    key = "{}-{}".format(system, arch)
    if key not in TARGETS:
        raise RuntimeError("Unsupported Office qualification host: " + key)
    return key


def target_option(parser):
    parser.add_argument("--target", choices=TARGETS, default=native_target())


def require_native(parser, target):
    if target != native_target():
        parser.error("Execution qualification requires a native " + target + " host; cross-target input inspection is not execution evidence")


def environment(profile, base=None):
    result = dict(os.environ if base is None else base, NODE_OPTIONS="", NODE_PATH="")
    if sys.platform == "win32":
        result["LOCALAPPDATA"] = str(profile)
    else:
        profile.mkdir(parents=True, exist_ok=True)
        result["HOME"] = str(profile)
    return result


def dependency_root(profile):
    return profile / ("MetaWork/OfficeDependencies" if sys.platform == "win32" else "Library/Application Support/MetaWork/OfficeDependencies")


def command(entry, name, arguments, env, timeout=None):
    if timeout is None:
        timeout = PREPARE_TIMEOUT if name.startswith("prepare") else 120
    if sys.platform == "win32":
        quoted = " ".join('"' + str(v) + '"' for v in [entry / name, *arguments])
        argv = 'cmd.exe /d /s /c "' + quoted + '"'
    else:
        argv = ["/bin/sh", str(entry / name.replace(".cmd", ".sh")), *map(str, arguments)]
    return subprocess.run(argv, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)


def extract(archive, destination):
    subprocess.run(["tar.exe" if sys.platform == "win32" else "/usr/bin/tar", "-xf", str(archive), "-C", str(destination)], check=True)
