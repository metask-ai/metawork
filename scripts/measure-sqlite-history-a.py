"""Run opt-in Stage A probes in fresh processes and a new disposable cache dir.

Build first: zig build build-sqlite-history-a-probes -Doptimize=ReleaseFast
  -p .zig-cache/sqlite-history-a/release (also Debug in .../debug).
Never reads an application profile, credentials or user history.
"""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    return subprocess.check_output(
        ["git", "-c", f"safe.directory={ROOT.as_posix()}", *args],
        cwd=ROOT, text=True, encoding="utf-8",
    ).strip()


def quantiles(values):
    values = sorted(values)
    return {"n": len(values), "p50": values[math.ceil(len(values)*.5)-1],
            "p99": values[math.ceil(len(values)*.99)-1], "max": values[-1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--modes", nargs="+", default=["release", "debug"])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if platform.system() != "Windows":
        raise SystemExit("This probe records Windows counters; run on Windows.")
    if args.repetitions < 1 or set(args.modes)-{"release", "debug"}:
        raise SystemExit("Invalid mode/repetition count")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    destination = ROOT/".zig-cache"/"sqlite-history-a"/f"run-{stamp}"
    destination.mkdir(parents=True, exist_ok=False)
    rows = []
    probes = list((ROOT/"tests/probes").glob("sqlite_history_a*"))
    inputs = probes + [Path(__file__).resolve(), ROOT/"build.zig", ROOT/"build.zig.zon",
                      ROOT/"src/storage/sql.zig", ROOT/"src/storage/sqlite.zig",
                      ROOT/"src/storage/sqlite/connection.zig", ROOT/"src/product/task/state.zig",
                      ROOT/"src/product/task/persistence.zig"]
    result = {"source_revision": git("rev-parse", "HEAD"), "started_utc": stamp,
              "branch": git("branch", "--show-current"), "git_status": git("status", "--short"),
              "platform": platform.platform(), "processor": platform.processor(),
              "python": sys.version, "artifact_directory": str(destination),
              "input_sha256": {str(p.relative_to(ROOT)): sha(p) for p in inputs},
              "rows": rows, "executables": {}, "errors": [],
              "io_semantics": "GetProcessIoCounters transfer bytes/operations; not physical NAND bytes or measured fsync count",
              "claim_scope": "isolated fixtures and actual existing backend; no Product integration, final schema/writer/growing Runtime or power-loss proof"}
    hardware = subprocess.run(["node", "-e", "const os=require('node:os');process.stdout.write(JSON.stringify({cpu:os.cpus()[0]?.model,logical_cpus:os.cpus().length,total_memory:os.totalmem(),free_memory:os.freemem(),release:os.release()}))"], capture_output=True, text=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
    if hardware.returncode != 0:
        raise RuntimeError("Cannot collect hardware identity")
    result["hardware"] = json.loads(hardware.stdout)
    try:
        environment = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "Get-MpComputerStatus | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureVersion | ConvertTo-Json -Compress"],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        result["defender"] = json.loads(environment.stdout) if environment.returncode == 0 else {"unavailable": True}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        result["defender"] = {"unavailable": True}

    def run(exe, name, env):
        started = time.perf_counter_ns()
        proc = subprocess.run([str(exe)], cwd=ROOT, env={**{k:v for k,v in os.environ.items() if not k.startswith("METAWORK_SQLITE_A_")}, **env},
                              capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
        log = proc.stdout+proc.stderr
        (destination/f"{name}.log").write_text(log, encoding="utf-8")
        if proc.returncode:
            raise RuntimeError(f"{name}: exit {proc.returncode}; see raw log")
        count = 0
        for line in log.splitlines():
            for prefix in ("A_MEMORY ", "A_BACKEND ", "A_PRIMITIVE ", "A_BUDGET "):
                if prefix in line:
                    row = json.loads(line.split(prefix, 1)[1])
                    rows.append({"run": name, "probe": prefix.strip(), **row})
                    count += 1
        if not count:
            raise RuntimeError(f"{name}: missing measurements")
        result.setdefault("process_wall_ns", {})[name] = time.perf_counter_ns()-started
        print(f"{name}: {count} records", flush=True)

    try:
        for mode in args.modes:
            binaries = ROOT/".zig-cache"/"sqlite-history-a"/mode/"bin"
            for exe in sorted(binaries.glob("*.exe")):
                result["executables"][f"{mode}/{exe.name}"] = {"bytes": exe.stat().st_size, "sha256": sha(exe)}
            for repetition in range(args.repetitions):
                backend = destination/f"{mode}-backend-{repetition}.sqlite"
                run(binaries/"sqlite-history-a-backend.exe", f"{mode}-backend-{repetition}", {"METAWORK_SQLITE_A_DB": str(backend)})
                result.setdefault("seeded_db_bytes", {})[backend.name] = backend.stat().st_size
                primitive_dir = destination/f"{mode}-primitives-{repetition}"
                primitive_dir.mkdir()
                run(binaries/"sqlite-history-a-primitives.exe", f"{mode}-primitives-{repetition}", {"METAWORK_SQLITE_A_DIR": str(primitive_dir)})
            cases = [
                ("control", dict(tasks=1, runs=16, body_bytes=4096, tools=0)),
                ("100x256_plain", dict(tasks=100, runs=256, body_bytes=4096, tools=0)),
                ("100x256_two_tools", dict(tasks=100, runs=256, body_bytes=1024, tools=2)),
                ("one_task_tool_dense", dict(tasks=1, runs=256, body_bytes=4096, tools=32)),
            ]
            for name, settings in cases:
                for repetition in range(args.repetitions):
                    config = {"approvals": 8, "compacts": 16, "budget_bytes": 256*1024*1024, **settings}
                    run(binaries/"sqlite-history-a-memory.exe", f"{mode}-{name}-{repetition}", {"METAWORK_SQLITE_A_CONFIG": json.dumps(config)})
            run(binaries/"sqlite-history-a-memory.exe", f"{mode}-field-boundary", {"METAWORK_SQLITE_A_BUDGET": "1"})
    except Exception as error:
        result["errors"].append(str(error))
        raise
    finally:
        result["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        result["summary"] = []
        for mode in args.modes:
            for groups in (1, 10, 100):
                for coalesced in (False, True):
                    values = [r for r in rows if r["probe"] == "A_BACKEND" and r.get("kind") == "drain" and r["run"].startswith(mode+"-") and r["groups"] == groups and r["coalesced"] == coalesced]
                    if values:
                        result["summary"].append({"mode": mode, "groups": groups, "coalesced": coalesced,
                                                  "wall_ms": quantiles([r["wall_ns"]/1e6 for r in values]),
                                                  "process_write_bytes": quantiles([r["process_write_bytes"] for r in values]),
                                                  "process_write_ops": quantiles([r["process_write_ops"] for r in values]),
                                                  "commits": sorted(set(r["commits"] for r in values))})
        output = args.output.resolve() if args.output else destination/"results.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
        print(f"Evidence: {output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
