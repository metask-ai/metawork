"""Real Application Job owner with the authenticated portable interpreter.

Controlled bootstrap script fixtures qualify lifetime, arguments and isolation;
they do not qualify input authentication, source downloads or installation.
"""
import ctypes
from ctypes import wintypes as w
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

if os.name != "nt" or len(sys.argv) < 3:
    raise SystemExit("Usage: check-office-bootstrap-process.py <authenticated-portable-python-directory> <office-process-probe.exe>")
PYTHON, HOST = [Path(value).resolve(strict=True) for value in sys.argv[1:3]]
del sys.argv[1:3]
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src/app/office_bootstrap"))
import host_job

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
kernel.OpenProcess.restype = w.HANDLE
kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
kernel.CloseHandle.argtypes = [w.HANDLE]
kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
kernel.CreateJobObjectW.restype = w.HANDLE
kernel.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]

FIXTURE = '''import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from host_job import join
join(sys.argv[-1])
import json,os,subprocess,tempfile,time
root=Path(__file__).resolve().parents[2]
mode=(root/'mode').read_text()
if mode=='normal':
 print(json.dumps({'args':sys.argv[1:],'cwd':os.getcwd(),'temp':tempfile.gettempdir(),
   'ambient':[os.environ.get(key) for key in ['METAWORK_QUALIFICATION_SECRET','PYTHONPATH','PYTHONSTARTUP','NODE_OPTIONS','PATH']]}))
 raise SystemExit(7)
child=subprocess.Popen([sys.executable,'-I','-S','-B','-c','import time;time.sleep(60)'],
 stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
(root/'pids.tmp').write_text(json.dumps({'pids':[os.getpid(),child.pid],'scratch':tempfile.gettempdir()}))
(root/'pids.tmp').replace(root/'pids.json')
while not (root/'go').exists():time.sleep(.005)
if mode=='orphan':raise SystemExit(0)
if mode=='stdout':print('x'*100000,flush=True)
if mode=='stderr':print('x'*100000,file=sys.stderr,flush=True)
time.sleep(60)
'''


class BootstrapProcess(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cache = ROOT / ".zig-cache/office-bootstrap-process-tests"
        cls.cache.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="安装 路径 ", dir=self.cache)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(PYTHON, self.root / "bootstrap")
        script = self.root / "seed/bootstrap"
        script.mkdir(parents=True)
        (script / "assemble.py").write_text(FIXTURE, encoding="utf-8")
        shutil.copyfile(ROOT / "src/app/office_bootstrap/host_job.py", script / "host_job.py")
        (self.root / "mode").write_text("normal")

    def start(self, mode="normal", timeout=15000, cancel=0):
        (self.root / "mode").write_text(mode)
        process = subprocess.Popen([str(HOST), "--bootstrap", str(self.root), str(timeout), str(cancel), "1" * 64, "2" * 64],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.addCleanup(self.stop, process)
        return process

    def stop(self, process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stderr)
        result = json.loads(stdout)
        self.assertIs(result["quiescent"], True)
        return result

    def clean_scratch(self, path):
        self.assertEqual(path.parent, self.cache)
        self.assertTrue(path.name.startswith(".host-"))
        if path.exists():
            path.rmdir()  # Only the known empty scratch, never arbitrary trees.

    def tree(self, mode="tree", **options):
        process = self.start(mode, **options)
        receipt = self.root / "pids.json"
        deadline = time.monotonic() + 8
        while not receipt.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(.005)
        self.assertTrue(receipt.exists(), self.finish(process) if process.poll() is not None else "No joined bootstrap receipt")
        data = json.loads(receipt.read_text())
        handles = []
        for pid in data["pids"]:
            handle = kernel.OpenProcess(0x100000 | 0x1000, False, pid)
            self.assertTrue(handle, ctypes.get_last_error())
            handles.append(handle)
            self.addCleanup(kernel.CloseHandle, handle)
        self.addCleanup(self.clean_scratch, Path(data["scratch"]))
        (self.root / "go").write_text("continue")
        return process, handles

    def quiet(self, handles):
        for handle in handles:
            self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0)

    def test_fixed_arguments_environment_and_nonzero_result(self):
        previous = dict(os.environ)
        for name in ["METAWORK_QUALIFICATION_SECRET", "PYTHONPATH", "PYTHONSTARTUP", "NODE_OPTIONS"]:
            os.environ[name] = "fixture-only"
        try:
            result = self.finish(self.start())
        finally:
            os.environ.clear()
            os.environ.update(previous)
        self.assertEqual(result["term"], {"exited": 7})
        captured = json.loads(result["stdout"])
        self.assertEqual(captured["args"][:5], [str(self.root / "seed"), str(self.root / "downloads"), str(self.root / "component"), "1" * 64, "2" * 64])
        self.assertEqual(captured["args"][-2], "--host-job")
        self.assertEqual(captured["ambient"], [None] * 5)
        self.assertEqual(captured["cwd"], captured["temp"])
        self.assertFalse(Path(captured["temp"]).exists())

    def test_host_hard_kill_closes_only_lifetime_handle(self):
        process, handles = self.tree()
        process.kill()
        process.communicate(timeout=10)
        self.quiet(handles)

    def test_cancel_physically_stops_bootstrap_and_descendant(self):
        process, handles = self.tree(cancel=1500)
        self.assertEqual(self.finish(process)["failure"], "Cancelled")
        self.quiet(handles)

    def test_timeout_physically_stops_bootstrap_and_descendant(self):
        process, handles = self.tree(timeout=2000)
        self.assertEqual(self.finish(process)["failure"], "OfficeTimedOut")
        self.quiet(handles)

    def test_success_with_orphan_is_rejected_and_cleaned(self):
        process, handles = self.tree("orphan")
        self.assertEqual(self.finish(process)["failure"], "OfficeDescendantsOutstanding")
        self.quiet(handles)

    def test_output_limits_stop_the_tree(self):
        for mode in ("stdout", "stderr"):
            with self.subTest(mode=mode):
                if mode == "stderr":
                    self.setUp()
                process, handles = self.tree(mode)
                self.assertEqual(self.finish(process)["failure"], "StreamTooLong")
                self.quiet(handles)

    def test_missing_unarmed_breakaway_or_sealed_job_fails_before_fixture_effects(self):
        script = self.root / "seed/bootstrap/assemble.py"
        python = self.root / "bootstrap/python.exe"
        missing = "Local\\MetaWork.Office.Op." + uuid.uuid4().hex
        result = subprocess.run([str(python), "-I", "-S", "-B", str(script), "--host-job", missing], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        for flags in (0, 0x2000 | 0x800, 0x2000 | 0x1000, 0x2000 | 0x8):
            name = "Local\\MetaWork.Office.Op." + uuid.uuid4().hex
            job = kernel.CreateJobObjectW(None, name)
            self.assertTrue(job, ctypes.get_last_error())
            try:
                if flags:
                    limits = host_job.ExtendedLimits()
                    limits.basic.flags = flags
                    limits.basic.active_process_limit = 1
                    self.assertTrue(kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
                result = subprocess.run([str(python), "-I", "-S", "-B", str(script), "--host-job", name], capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
            finally:
                kernel.CloseHandle(job)
        self.assertFalse((self.root / "pids.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
