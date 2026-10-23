"""Observe real Windows Application/Product resource performance, outside UI.

The paused native probe is assigned to an accounting Job before it creates any
worker or engine. Kernel CPU totals and peak aggregate committed memory include
all descendants. Active process peaks are sampled lower bounds, not RSS peaks.
Compilation, fixture creation and full component hashing are outside timings.
No production budget is changed and these synthetic inputs do not qualify the
entire accepted file envelope, the App, WebView or clean-machine installation.
"""
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import subprocess
import sys
import tempfile
import threading
import time

if os.name != "nt" or len(sys.argv) != 4:
    raise SystemExit("Usage on Windows: check-office-preview-performance.py <component> <resource-probe.exe> <performance-fixtures>")
COMPONENT, PROBE, FIXTURES = [Path(value).resolve(strict=True) for value in sys.argv[1:]]
ROOT = Path(__file__).resolve().parents[1]
MANIFEST = COMPONENT / "office-runtime.json"
MANIFEST_BYTES = MANIFEST.read_bytes()
MANIFEST_SHA = hashlib.sha256(MANIFEST_BYTES).hexdigest()
manifest = json.loads(MANIFEST_BYTES)
assert manifest["schema"] == 1 and manifest["target"] == "x86_64-windows-msvc"

kernel = ctypes.WinDLL("kernel32", use_last_error=True)


class Accounting(ctypes.Structure):
    _fields_ = [(name, ctypes.c_int64) for name in ("user", "kernel", "period_user", "period_kernel")] + [
        (name, wintypes.DWORD) for name in ("page_faults", "total_processes", "active_processes", "terminated_processes")]


class BasicLimits(ctypes.Structure):
    _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                ("flags", wintypes.DWORD), ("minimum_working_set", ctypes.c_size_t),
                ("maximum_working_set", ctypes.c_size_t), ("active_process_limit", wintypes.DWORD),
                ("affinity", ctypes.c_size_t), ("priority_class", wintypes.DWORD),
                ("scheduling_class", wintypes.DWORD)]


class ExtendedLimits(ctypes.Structure):
    _fields_ = [("basic", BasicLimits), ("io_counters", ctypes.c_uint64 * 6),
                ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t)]


class MemoryStatus(ctypes.Structure):
    _fields_ = [("length", wintypes.DWORD), ("load", wintypes.DWORD)] + [
        (name, ctypes.c_uint64) for name in ("total_physical", "available_physical", "total_pagefile",
                                            "available_pagefile", "total_virtual", "available_virtual", "reserved")]


kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
kernel.CreateJobObjectW.restype = wintypes.HANDLE
kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
kernel.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p]
kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel.GlobalMemoryStatusEx.argtypes = [ctypes.POINTER(MemoryStatus)]


def checked(result):
    if not result:
        raise ctypes.WinError(ctypes.get_last_error())
    return result


def query_job(job, kind, record):
    checked(kernel.QueryInformationJobObject(job, kind, ctypes.byref(record), ctypes.sizeof(record), None))
    return record


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory():
    assert MANIFEST.read_bytes() == MANIFEST_BYTES
    expected = {entry["path"]: entry for entry in manifest["files"]}
    found = set()
    total = 0
    pending = [COMPONENT]
    while pending:
        with os.scandir(pending.pop()) as entries:
            for item in entries:
                # Windows directory enumeration already provides attributes and
                # size. Reject every reparse tag without opening each member
                # again just to ask whether it is a junction or symlink.
                stat = item.stat(follow_symlinks=False)
                assert not stat.st_file_attributes & 0x400, item.path
                if item.is_dir(follow_symlinks=False):
                    pending.append(Path(item.path))
                    continue
                assert item.is_file(follow_symlinks=False), item.path
                path = Path(item.path)
                relative = path.relative_to(COMPONENT).as_posix()
                if relative == "office-runtime.json":
                    continue
                entry = expected[relative]
                assert stat.st_size == entry["bytes"] and sha(path) == entry["sha256"], relative
                found.add(relative)
                total += entry["bytes"]
    assert found == expected.keys()
    return {"files": len(found), "bytes": total, "manifestSha256": MANIFEST_SHA}


cache = ROOT / ".zig-cache/pvp"
cache.mkdir(parents=True, exist_ok=True)
directory = Path(tempfile.mkdtemp(prefix="r-", dir=cache))
inputs = {name: {"bytes": (FIXTURES / name).stat().st_size, "sha256": sha(FIXTURES / name)}
          for name in ("pages.docx", "slides.pptx", "dense.xlsx", "pages.pdf", "cancel.docx")}


def measure(name, mode, index):
    case = directory / str(index)
    case.mkdir()
    data = case / "data"
    data.mkdir()
    source = inputs[name]
    args = [str(PROBE), str(COMPONENT), str(FIXTURES), name, str(data), str(source["bytes"]), source["sha256"], MANIFEST_SHA, mode]
    job = checked(kernel.CreateJobObjectW(None, None))
    process = None
    try:
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # KILL_ON_JOB_CLOSE, no resource limit.
        checked(kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
        with (case / "stderr.txt").open("wb") as stderr:
            process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                       creationflags=subprocess.CREATE_NO_WINDOW, cwd=ROOT)
            ready = queue.Queue(maxsize=1)
            reader = threading.Thread(target=lambda: ready.put(process.stdout.readline(4096)), daemon=True)
            reader.start()
            line = ready.get(timeout=10)
            reader.join(timeout=1)
            assert json.loads(line) == {"observer_ready": True}, line
            # This child is paused on stdin and cannot exit or spawn descendants.
            handle = checked(kernel.OpenProcess(0x0101, False, process.pid))  # SET_QUOTA | TERMINATE
            try:
                checked(kernel.AssignProcessToJobObject(job, handle))
            finally:
                checked(kernel.CloseHandle(handle))
            attached = query_job(job, 1, Accounting())
            assert attached.total_processes == attached.active_processes == 1
            start = time.perf_counter()
            process.stdin.write(b"g")
            process.stdin.flush()
            active_peak = 1
            samples = 0
            while process.poll() is None:
                active_peak = max(active_peak, query_job(job, 1, Accounting()).active_processes)
                samples += 1
                if time.perf_counter() - start > 180:
                    raise TimeoutError("Preview performance probe exceeded 180 seconds")
                time.sleep(.02)
            stdout, _ = process.communicate(timeout=5)
            wall_ms = (time.perf_counter() - start) * 1000
        assert process.returncode == 0, (case / "stderr.txt").read_text(encoding="utf-8", errors="replace")[:8192]
        result = json.loads(stdout)
        accounting = query_job(job, 1, Accounting())
        peak = query_job(job, 9, ExtendedLimits())
        assert accounting.active_processes == 0, "Root exit alone does not prove a quiet descendant tree"
        assert result["lease_released"] and result["product_lane"]
        assert result["resources"] == (1 if mode == "performance_single" else 2)
        if mode == "performance_cancel":
            assert result["cancel_requested_ms"] >= 800 and result["cancel_to_release_ms"] >= 0
            assert result["read_ms"] == []
        else:
            assert len(result["read_ms"]) == result["resources"] * 6
            assert all(page_count > 0 for page_count in result["pages"])
            if name.endswith(".xlsx"):
                assert result["region_count"] == result["resources"] * 3
        assert not list((data / "pv").iterdir()), "Successful release must remove physical preview resources"
        assert sha(FIXTURES / name) == source["sha256"]
        cpu_ms = (accounting.user + accounting.kernel) / 10000
        assert cpu_ms > 0 and peak.peak_job_memory > 0 and accounting.total_processes > 1
        return {"name": name, "mode": mode, "wallMs": wall_ms, "cpuMs": cpu_ms,
                "cpuCoreEquivalent": cpu_ms / wall_ms,
                "peakJobCommittedBytes": peak.peak_job_memory,
                "peakProcessCommittedBytes": peak.peak_process_memory,
                "sampledPeakActiveProcesses": active_peak, "samples": samples,
                "totalProcesses": accounting.total_processes, "finalActiveProcesses": 0, "result": result}
    finally:
        try:
            if process is not None:
                if process.poll() is None:
                    # Stop the entire owned tree on any observation/assertion error.
                    checked(kernel.TerminateJobObject(job, 1))
                    process.kill()
                process.communicate(timeout=10)
                deadline = time.monotonic() + 5
                accounting = query_job(job, 1, Accounting())
                while accounting.active_processes != 0 and time.monotonic() < deadline:
                    time.sleep(.02)
                    accounting = query_job(job, 1, Accounting())
                assert accounting.active_processes == 0, "Observer cleanup could not prove a quiet process tree"
                peak = query_job(job, 9, ExtendedLimits())
                (case / "observer-final.json").write_text(json.dumps({
                    "activeProcesses": accounting.active_processes, "totalProcesses": accounting.total_processes,
                    "cpuMs": (accounting.user + accounting.kernel) / 10000,
                    "peakJobCommittedBytes": peak.peak_job_memory,
                }, indent=2) + "\n", encoding="utf-8")
        finally:
            checked(kernel.CloseHandle(job))


memory = MemoryStatus()
memory.length = ctypes.sizeof(memory)
checked(kernel.GlobalMemoryStatusEx(ctypes.byref(memory)))
source_diff = subprocess.check_output(["git", "-c", "safe.directory=E:/project/metawork", "diff", "--binary", "--",
                                       "src/app/office_preview.zig", "tests/office_preview_resource.zig"], cwd=ROOT)
(directory / "source.patch").write_bytes(source_diff)
evidence = {"schema": 1, "scope": "Synthetic Windows Application resource plus physical Product lane; excludes App/Bridge/Renderer and full supported-input envelope",
            "measurement": "20ms sampled active process count; kernel Job aggregate CPU and peak committed bytes across complete descendant tree; not working-set/RSS; no cold OS-cache claim",
            "componentManifestSha256": MANIFEST_SHA, "probeSha256": sha(PROBE),
            "collectorSha256": sha(Path(__file__)), "fixtureGeneratorSha256": sha(ROOT / "scripts/create-office-preview-performance-fixtures.mjs"),
            "probeSourceSha256": sha(ROOT / "tests/office_preview_resource.zig"),
            "sourceDiffSha256": hashlib.sha256(source_diff).hexdigest(),
            "startedAt": datetime.now(timezone.utc).isoformat(),
            "revision": subprocess.check_output(["git", "-c", "safe.directory=E:/project/metawork", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "machine": {"platform": platform.platform(), "cpu": platform.processor(), "logicalCpus": os.cpu_count(),
                        "physicalBytes": memory.total_physical}, "inputs": inputs, "results": [], "failures": [], "passed": False}
print(json.dumps({"stage": "inventory_before", "directory": str(directory)}), flush=True)
evidence["inventoryBefore"] = inventory()
try:
    cases = [(name, "performance_single") for _ in range(2) for name in ("pages.docx", "slides.pptx", "dense.xlsx", "pages.pdf")]
    cases += [("pages.docx", "performance_pair"), ("dense.xlsx", "performance_pair"), ("cancel.docx", "performance_cancel")]
    for index, (name, mode) in enumerate(cases):
        print(json.dumps({"stage": "start", "case": index, "name": name, "mode": mode}), flush=True)
        try:
            result = measure(name, mode, index)
        except Exception as failure:
            evidence["failures"].append({"case": index, "name": name, "mode": mode,
                                         "type": type(failure).__name__, "message": str(failure)[:8192]})
            print(json.dumps({"stage": "failed", **evidence["failures"][-1]}), flush=True)
            continue
        evidence["results"].append(result)
        print(json.dumps({"case": len(evidence["results"]), "name": name, "mode": mode,
                          "wallMs": round(result["wallMs"]), "cpuMs": round(result["cpuMs"]),
                          "peakJobMiB": round(result["peakJobCommittedBytes"] / 1048576, 1)}), flush=True)
    evidence["passed"] = not evidence["failures"] and len(evidence["results"]) == len(cases)
finally:
    print(json.dumps({"stage": "inventory_after"}), flush=True)
    evidence["inventoryAfter"] = inventory()
    assert evidence["inventoryBefore"] == evidence["inventoryAfter"]
    evidence["finishedAt"] = datetime.now(timezone.utc).isoformat()
    (directory / "evidence.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"evidence": str(directory / "evidence.json"), "cases": len(evidence["results"])}))
if evidence["failures"]:
    raise SystemExit("Preview performance qualification failed; all independent outcomes retained")
