"""Qualify actual canonical AgentCore Shell abort and Host death on Windows.

Usage: python scripts/check-office-core-shell.py <accepted-component-root>
Only a loopback fixture provider is used. Physical exit is observed through
handles acquired while the entire Office/LibreOffice tree is alive, not PIDs.
"""
import base64
import ctypes
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
if os.name != "nt" or len(sys.argv) not in (2, 4) or (len(sys.argv) == 4 and sys.argv[2] != "--entry"):
    raise SystemExit("Usage on Windows: check-office-core-shell.py <accepted-component-root> [--entry new-office.exe]")
COMPONENT = Path(sys.argv[1]).resolve(strict=True)
ENTRY = Path(sys.argv[3]).resolve(strict=True) if len(sys.argv) == 4 else None
for relative in ("bin/office.exe", "engine/program/soffice.com", "python/bin/python.exe"):
    if not (COMPONENT / relative).is_file():
        raise SystemExit(f"Missing component resource: {relative}")

kernel = ctypes.WinDLL("kernel32", use_last_error=True)


class ProcessEntry(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("usage", wintypes.DWORD),
                ("pid", wintypes.DWORD), ("heap", ctypes.c_size_t),
                ("module", wintypes.DWORD), ("threads", wintypes.DWORD),
                ("parent", wintypes.DWORD), ("priority", wintypes.LONG),
                ("flags", wintypes.DWORD), ("exe", wintypes.WCHAR * 260)]


kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
kernel.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
kernel.OpenJobObjectW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
kernel.OpenJobObjectW.restype = wintypes.HANDLE
kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]


def descendants(parent):
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = ProcessEntry()
        entry.size = ctypes.sizeof(entry)
        processes = []
        valid = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while valid:
            processes.append((entry.pid, entry.parent, entry.exe))
            valid = kernel.Process32NextW(snapshot, ctypes.byref(entry))
        found = {}
        parents = {parent}
        while True:
            children = [(pid, name) for pid, owner, name in processes
                        if owner in parents and pid != parent and pid not in found]
            if not children:
                return found
            found.update(children)
            parents.update(pid for pid, _ in children)
    finally:
        kernel.CloseHandle(snapshot)


def inventory():
    return {path.relative_to(COMPONENT).as_posix():
            (stat.S_IFMT(info.st_mode), info.st_size, info.st_mtime_ns)
            for path in COMPONENT.rglob("*") for info in [path.lstat()]}


def scope_record(pid):
    handle = kernel.OpenProcess(0x1000, False, pid)
    assert handle
    born, exited, kernel_time, user = [wintypes.FILETIME() for _ in range(4)]
    try:
        assert kernel.GetProcessTimes(handle, ctypes.byref(born), ctypes.byref(exited), ctypes.byref(kernel_time), ctypes.byref(user))
    finally:
        kernel.CloseHandle(handle)
    return b"MWOFS001" + struct.pack("<IIQ", pid, 0, (born.dwHighDateTime << 32) | born.dwLowDateTime)


def rejected_scopes(scratch, resource_root):
    sibling = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)"])
    try:
        valid = scope_record(os.getpid())
        variants = {
            "missing": None,
            "truncated": valid[:-1],
            "extra": valid + b"x",
            "magic": b"incorrect" + valid[9:],
            "reserved": valid[:12] + b"\x01\0\0\0" + valid[16:],
            "birth": valid[:16] + struct.pack("<Q", struct.unpack("<Q", valid[16:])[0] ^ 1),
            "nonancestor": scope_record(sibling.pid),
        }
        marker = scratch / "must-not-execute"
        for name, data in variants.items():
            record = scratch / "host.scope"
            record.unlink(missing_ok=True)
            if data is not None:
                record.write_bytes(data)
            result = subprocess.run([str(resource_root / "bin/office.exe"), "python", "-c",
                                     "from pathlib import Path;Path(" + repr(str(marker)) + ").write_text('executed')"],
                                    cwd=scratch, capture_output=True, timeout=5)
            assert result.returncode != 0 and not marker.exists(), name
        (scratch / "host.scope").unlink(missing_ok=True)
        alias = str(resource_root / "bin/office.exe").upper()
        result = subprocess.run([alias, "python", "-c",
                                 "from pathlib import Path;Path(" + repr(str(marker)) + ").write_text('executed')"],
                                cwd=scratch, capture_output=True, timeout=5)
        assert result.returncode != 0 and not marker.exists(), "case-alias"
        variants["case-alias"] = None
        (scratch / "host.scope").write_bytes(valid)
        result = subprocess.run([str(resource_root / "bin/office.exe"), "python", "-c",
                                 "from pathlib import Path;Path(" + repr(str(marker)) + ").write_text('executed')"],
                                cwd=scratch, capture_output=True, timeout=5)
        assert result.returncode != 0 and not marker.exists(), "missing-version-owner"
        variants["missing-version-owner"] = None
        print(json.dumps({"scenario": "invalid-host-scopes", "result": "passed", "cases": list(variants)}), flush=True)
    finally:
        sibling.kill()
        sibling.wait(timeout=5)


def events(payloads):
    return "".join("data: " + json.dumps(value) + "\n\n" for value in payloads).encode()


class Provider(BaseHTTPRequestHandler):
    tool_command = None
    failure = None
    requests = 0
    results = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            assert self.path == "/v1/messages", self.path
            size = int(self.headers.get("content-length", "0"))
            assert 0 < size <= 1024 * 1024
            payload = json.loads(self.rfile.read(size))
            complete = any(part.get("type") == "tool_result"
                           for message in payload["messages"]
                           for part in message.get("content", []) if isinstance(part, dict))
            Provider.requests += 1
            if complete:
                Provider.results.append(str(payload["messages"][-1])[:4096])
            start = {"type": "message_start", "message": {
                "id": "office_lifetime", "role": "assistant", "model": "fixture",
                "usage": {"input_tokens": 1, "output_tokens": 1}}}
            if complete:
                block = {"type": "content_block_start", "index": 0,
                         "content_block": {"type": "text", "text": ""}}
                delta = {"type": "content_block_delta", "index": 0,
                         "delta": {"type": "text_delta", "text": "completed"}}
            else:
                block = {"type": "content_block_start", "index": 0,
                         "content_block": {"type": "tool_use", "id": "office_tree",
                                           "name": "Bash", "input": {}}}
                delta = {"type": "content_block_delta", "index": 0,
                         "delta": {"type": "input_json_delta", "partial_json": json.dumps({
                             "command": self.tool_command})}}
            body = events([start, block, delta, {"type": "content_block_stop", "index": 0},
                           {"type": "message_delta", "delta": {
                               "stop_reason": "end_turn" if complete else "tool_use"},
                            "usage": {"output_tokens": 1}}, {"type": "message_stop"}])
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as failure:
            Provider.failure = str(failure)
            self.send_error(400)


FIXTURE = '''import os,subprocess,sys,time
from pathlib import Path
component=Path(sys.argv[1]); scratch=Path(sys.argv[2])
environment=dict(os.environ)
environment['SAL_DISABLE_OPENCL']='1'
environment['UNO_SHARED_PACKAGES_CACHE']=(scratch/'cache').as_uri()
environment.pop('SC_FORCE_CALCULATION',None)
subprocess.Popen([str(component/'engine/program/soffice.com'),
    '-env:UserInstallation='+(scratch/'profile').as_uri(), '--headless','--nologo',
    '--nodefault','--nofirststartwizard','--norestore',
    '--accept=pipe,name=office_qualification_'+scratch.name+';urp;StarOffice.ComponentContext'],
    env=environment)
subprocess.Popen([sys.executable,'-I','-S','-c','import time;time.sleep(120)'])
(scratch/'started').write_text('started')
time.sleep(120)
'''


def build(scratch, server):
    # Delegate exact artifact acceptance to the existing canonical verifier.
    source = """import {verifyStagedAgentCoreBundle} from './scripts/verify-staged-agentcore-bundle.mjs';
const b=await verifyStagedAgentCoreBundle(process.cwd(),{targetId:'x86_64-windows-msvc'});
console.log(JSON.stringify({root:b.root,target:b.target,rg:b.manifest.runtime_assets[0].path}));"""
    checked = subprocess.run(["node", "--input-type=module", "-e", source], cwd=ROOT,
                             check=True, capture_output=True, text=True, timeout=60)
    bundle = json.loads(checked.stdout)
    subprocess.run(["zig", "build", "build-office-core-shell-probe", "-Dtarget=x86_64-windows-msvc",
                    "-Doptimize=ReleaseSafe", "--prefix", str(scratch / "probe-out"),
                    "--global-cache-dir", str(ROOT / ".zig-cache/office-bootstrap-global")],
                   cwd=ROOT, check=True, timeout=180)
    environment = dict(os.environ)
    environment["RG_BIN"] = str(Path(bundle["root"]) / bundle["rg"])
    environment["METAWORK_OFFICE_CORE_URL"] = f"http://127.0.0.1:{server.server_port}/v1/messages"
    environment["METAWORK_OFFICE_CORE_WORKSPACE"] = str(scratch)
    return scratch / "probe-out/bin/office-core-shell.exe", environment


def qualify(executable, environment, scratch, resource_root, mode):
    case = scratch / mode
    case.mkdir()
    fixture = scratch / "fixture.py"
    fixture.write_text(FIXTURE, encoding="utf-8")
    arguments = [str(resource_root / "bin/office.exe"), "python", str(fixture), str(COMPONENT), str(case)]
    script = "& " + " ".join("'" + value.replace("'", "''") + "'" for value in arguments)
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    Provider.tool_command = "powershell -NoProfile -NonInteractive -EncodedCommand " + encoded
    operation_environment = dict(environment, METAWORK_OFFICE_CORE_INSTALL_ID=resource_root.name)
    host = subprocess.Popen([str(executable)], cwd=scratch, env=operation_environment,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    handles = []
    control_child = None
    try:
        scope = scope_record(host.pid)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if (scratch / "host.scope").exists() and (scratch / "host.scope").read_bytes() == scope:
                break
            assert host.poll() is None
            time.sleep(.01)
        else:
            raise AssertionError("Application's native Host scope did not match the process observed by the controller")
        host.stdin.write(b"s")
        host.stdin.flush()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            assert host.poll() is None, host.communicate(timeout=5)[1].decode(errors="replace")
            tree = descendants(host.pid)
            names = [name.lower() for name in tree.values()]
            if (case / "started").exists() and all(name in names for name in
                    ("office.exe", "python.exe", "soffice.com", "soffice.bin")):
                for pid, name in tree.items():
                    handle = kernel.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
                    if not handle:
                        raise ctypes.WinError(ctypes.get_last_error())
                    handles.append((name, handle))
                assert all(kernel.WaitForSingleObject(handle, 0) == 258 for _, handle in handles)
                break
            time.sleep(.01)
        else:
            raise AssertionError(f"No complete live Office/Core Shell tree was observed: {tree}; requests={Provider.requests}; marker={(case / 'started').exists()}; providerFailure={Provider.failure}; toolResults={Provider.results}")
        if mode == "abort":
            host.stdin.write(b"a")
            host.stdin.flush()
        elif mode == "retire":
            # Positive control in the same job hierarchy: assignment succeeds
            # before sealing, so the later refusal observes the changed limit.
            job = kernel.OpenJobObjectW(1, False, "Local\\MetaWork.Office.Version." + resource_root.name)
            assert job
            control_child = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)"])
            handle = kernel.OpenProcess(0x100000 | 0x1000 | 0x0101, False, control_child.pid)
            assert handle
            handles.append(("assignment-control-python.exe", handle))
            try:
                assert kernel.AssignProcessToJobObject(job, handle) != 0
            finally:
                kernel.CloseHandle(job)
            host.stdin.write(b"q")
            host.stdin.flush()
        else:
            host.kill()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if all(kernel.WaitForSingleObject(handle, 0) == 0 for _, handle in handles):
                break
            time.sleep(.01)
        alive = [name for name, handle in handles if kernel.WaitForSingleObject(handle, 0) != 0]
        assert not alive, f"{mode}: physical process handles still running: {alive}"
        if mode == "retire":
            deadline = time.monotonic() + 8
            while not (scratch / "version.sealed").exists() and time.monotonic() < deadline:
                assert host.poll() is None
                time.sleep(.01)
            assert (scratch / "version.sealed").exists()
            # A valid new caller still cannot enter the sealed version while
            # reclamation holds its reservation. No model or source pin is used.
            (scratch / "host.scope").write_bytes(scope_record(os.getpid()))
            marker = scratch / "sealed-must-not-execute"
            result = subprocess.run([str(resource_root / "bin/office.exe"), "python", "-c",
                                     "from pathlib import Path;Path(" + repr(str(marker)) + ").write_text('executed')"],
                                    cwd=scratch, capture_output=True, timeout=5)
            assert result.returncode != 0 and not marker.exists()
            # Check the kernel limit as well as the launcher's preflight: a
            # caller that read the old limits before sealing still cannot join.
            job = kernel.OpenJobObjectW(1, False, "Local\\MetaWork.Office.Version." + resource_root.name)
            assert job
            outsider = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"])
            outsider_handle = kernel.OpenProcess(0x100000 | 0x1000 | 0x0101, False, outsider.pid)
            assert outsider_handle
            try:
                assert kernel.AssignProcessToJobObject(job, outsider_handle) == 0
            finally:
                kernel.CloseHandle(outsider_handle)
                kernel.CloseHandle(job)
                if outsider.poll() is None:
                    outsider.kill()
                outsider.wait(timeout=5)
            entry = resource_root / "bin/office.exe"
            retired_entry = resource_root / "bin/office.retired.exe"
            assert resource_root.resolve().is_relative_to(scratch.resolve())
            entry.rename(retired_entry)
            retired_entry.rename(entry)
            host.stdin.write(b"x")
            host.stdin.flush()
            host.wait(timeout=10)
            assert host.returncode == 0
        if mode == "abort":
            host.wait(timeout=10)
            assert host.returncode == 0, host.stderr.read().decode(errors="replace")
        assert Provider.failure is None, Provider.failure
        print(json.dumps({"scenario": mode, "result": "passed", "observed": [name for name, _ in handles]}), flush=True)
    finally:
        # Failure cleanup uses only pre-acquired handles, never a reused PID.
        if not handles and host.poll() is None:
            for pid, name in descendants(host.pid).items():
                handle = kernel.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
                if handle:
                    handles.append((name, handle))
        if host.poll() is None:
            host.kill()
        for _, handle in reversed(handles):
            if kernel.WaitForSingleObject(handle, 0) != 0:
                kernel.TerminateProcess(handle, 1)
                kernel.WaitForSingleObject(handle, 5000)
            kernel.CloseHandle(handle)
        stdout, stderr = host.communicate(timeout=10)
        if control_child is not None:
            if control_child.poll() is None:
                control_child.kill()
            control_child.wait(timeout=5)
        if stderr:
            print(stderr.decode(errors="replace"), file=sys.stderr, flush=True)


before = inventory()
base = ROOT / ".zig-cache/office-core-shell-qualification"
base.mkdir(parents=True, exist_ok=True)
scratch = base / ("run-" + uuid.uuid4().hex[:12])
scratch.mkdir()
server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    executable, environment = build(scratch, server)
    resource_root = scratch / "versions" / uuid.uuid4().hex
    (resource_root / "bin").mkdir(parents=True)
    shutil.copyfile(ENTRY or COMPONENT / "bin/office.exe", resource_root / "bin/office.exe")
    links = []
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    for name in ("python", "engine", "node", "tools"):
        link = resource_root / name
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        "New-Item -ItemType Junction -Path " + quote(link) + " -Target " +
                        quote(COMPONENT / name) + " | Out-Null"], check=True, timeout=15)
        links.append(link)
    rejected_scopes(scratch, resource_root)
    failures = []
    for scenario in ("abort", "host-hard-kill", "retire"):
        try:
            qualify(executable, environment, scratch, resource_root, scenario)
        except Exception as failure:
            failures.append(str(failure))
            print(json.dumps({"scenario": scenario, "result": "failed", "failure": str(failure)}), flush=True)
    assert inventory() == before, "Immutable component changed during Core Shell qualification"
    assert not failures, failures
    print(json.dumps({"result": "passed", "providerRequests": Provider.requests, "scratch": str(scratch)}), flush=True)
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    # Remove only the private resource junctions, never their accepted targets.
    for link in locals().get("links", []):
        if link.exists():
            link.rmdir()
