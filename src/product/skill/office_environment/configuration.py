"""Select the exact native target from the generated Office manifest."""
import json
import os
from pathlib import Path
import platform
import sys


def current():
    os_name = {"win32": "windows", "darwin": "macos"}.get(sys.platform)
    arch = {"AMD64": "x86_64", "x86_64": "x86_64", "ARM64": "aarch64", "arm64": "aarch64"}.get(platform.machine())
    key = "{}-{}".format(os_name, arch)
    source = json.loads((Path(__file__).parent / "environment.json").read_text(encoding="utf-8"))
    if source["schemaVersion"] != 2 or key not in source["targets"] or os.environ.get("METAWORK_OFFICE_TARGET", key) != key:
        raise RuntimeError("Unsupported private Office Python target")
    return source["targets"][key]
