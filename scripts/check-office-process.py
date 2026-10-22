"""Real Application/launcher Windows process-tree qualification.

Uses private fixtures and previously acquired process handles, never PID reuse
or a vanished console window as evidence of physical termination.
"""
import ctypes
from ctypes import wintypes
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

if os.name != "nt" or len(sys.argv) < 4:
    raise SystemExit("Usage on Windows: check-office-process.py <prepared-component> <new-office.exe> <office-process-probe.exe>")
PREPARED, ENTRY, HOST = [Path(value).resolve(strict=True) for value in sys.argv[1:4]]
del sys.argv[1:4]
ROOT = Path(__file__).resolve().parents[1]
kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
kernel.CreateJobObjectW.restype = wintypes.HANDLE

TREE = '''import json,os,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
child=subprocess.Popen([sys.executable,'-I','-S','-c','import time;time.sleep(60)'],
    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
(root/'pids.tmp').write_text(json.dumps({'entry':os.getppid(),'python':os.getpid(),'descendant':child.pid}))
(root/'pids.tmp').replace(root/'pids.json')
while not (root/'go').exists():time.sleep(.005)
'''


class OfficeProcess(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cache = ROOT / ".zig-cache/office-process-regression"
        cache.mkdir(parents=True, exist_ok=True)
        cls.scratch = tempfile.TemporaryDirectory(prefix="Host Office 路径 ", dir=cache)
        cls.root = Path(cls.scratch.name)
        shutil.copytree(PREPARED / "python", cls.root / "python")
        (cls.root / "bin").mkdir()
        shutil.copyfile(ENTRY, cls.root / "bin/office.exe")
        (cls.root / "engine/program").mkdir(parents=True)
        (cls.root / "tools").mkdir()
        cls.script = cls.root / "tools/office.py"

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        (self.root / "pids.json").unlink(missing_ok=True)
        (self.root / "go").unlink(missing_ok=True)

    def start(self, source, timeout=15000, cancel=0):
        self.script.write_text(source, encoding="utf-8")
        process = subprocess.Popen([str(HOST), str(self.root), str(timeout), str(cancel)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.addCleanup(self.stop, process)
        return process

    def stop(self, process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=12)
        self.assertEqual(process.returncode, 0, stderr)
        return json.loads(stdout)

    def tree(self, suffix="time.sleep(60)\n", **options):
        process = self.start(TREE + suffix, **options)
        receipt = self.root / "pids.json"
        deadline = time.monotonic() + 8
        while not receipt.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(.005)
        self.assertTrue(receipt.exists(), self.finish(process) if process.poll() is not None else "No fixture receipt")
        # The fixture cannot exit until these handles have been acquired.
        pids = json.loads(receipt.read_text())
        handles = []
        for pid in pids.values():
            handle = kernel.OpenProcess(0x100000 | 0x1000, False, pid)
            self.assertTrue(handle, ctypes.get_last_error())
            handles.append(handle)
            self.addCleanup(kernel.CloseHandle, handle)
        (self.root / "go").write_text("continue")
        return process, handles

    def assert_quiet(self, handles):
        for handle in handles:
            self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0)

    def test_normal_and_nonzero_return_preserve_result_without_protocol_arguments(self):
        result = self.finish(self.start("import json,sys;print(json.dumps(sys.argv[1:]));raise SystemExit(7)"))
        self.assertEqual(result["term"], {"exited": 7})
        self.assertEqual(json.loads(result["stdout"]), ["selftest"])

    def test_host_environment_and_temporary_files_are_scoped_to_its_transaction(self):
        source = "import json,os,tempfile;print(json.dumps({'cwd':os.getcwd(),'temp':tempfile.gettempdir(),'ambient':os.environ.get('METAWORK_QUALIFICATION_SECRET')}))"
        previous = os.environ.get("METAWORK_QUALIFICATION_SECRET")
        os.environ["METAWORK_QUALIFICATION_SECRET"] = "fixture-only-marker"
        try:
            result = self.finish(self.start(source))
        finally:
            if previous is None:
                os.environ.pop("METAWORK_QUALIFICATION_SECRET", None)
            else:
                os.environ["METAWORK_QUALIFICATION_SECRET"] = previous
        captured = json.loads(result["stdout"])
        self.assertIsNone(captured["ambient"])
        self.assertEqual(captured["cwd"], captured["temp"])
        self.assertNotEqual(Path(captured["temp"]), self.root)
        self.assertFalse(Path(captured["temp"]).exists(), "Qualification must remove its owned transaction scratch")

    def test_hard_killed_application_closes_the_only_lifetime_handle(self):
        process, handles = self.tree()
        process.kill()
        process.communicate(timeout=10)
        self.assert_quiet(handles)

    def test_timeout_joins_entry_and_all_descendants(self):
        process, handles = self.tree(timeout=1800)
        self.assertEqual(self.finish(process)["failure"], "OfficeTimedOut")
        self.assert_quiet(handles)

    def test_cancel_joins_entry_before_terminating_job(self):
        process, handles = self.tree(cancel=1200)
        self.assertEqual(self.finish(process)["failure"], "Cancelled")
        self.assert_quiet(handles)

    def test_root_success_with_orphan_is_rejected_and_physically_cleaned(self):
        process, handles = self.tree(suffix="")
        self.assertEqual(self.finish(process)["failure"], "OfficeDescendantsOutstanding")
        self.assert_quiet(handles)

    def test_stdout_and_stderr_limits_stop_the_complete_tree(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                self.setUp()
                process, handles = self.tree(suffix=f"print('x'*100000,file=sys.{stream},flush=True)\ntime.sleep(60)\n")
                self.assertEqual(self.finish(process)["failure"], "StreamTooLong")
                self.assert_quiet(handles)

    def test_missing_or_invalid_host_job_fails_before_python(self):
        self.script.write_text("print('must not execute')", encoding="utf-8")
        for name in ("arbitrary", "Local\\MetaWork.Office." + "0" * 32):
            result = subprocess.run([str(self.root / "bin/office.exe"), "--host-job", name, "selftest"],
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")

    def test_unarmed_host_job_is_rejected_before_python(self):
        self.script.write_text("print('must not execute')", encoding="utf-8")
        name = "Local\\MetaWork.Office." + uuid.uuid4().hex
        # A real, validly named Job without KILL_ON_JOB_CLOSE must be refused.
        job = kernel.CreateJobObjectW(None, name)
        self.assertTrue(job, ctypes.get_last_error())
        try:
            result = subprocess.run([str(self.root / "bin/office.exe"), "--host-job", name, "selftest"],
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
        finally:
            kernel.CloseHandle(job)

    def test_standalone_shell_entry_regressions(self):
        subprocess.run([sys.executable, str(ROOT / "scripts/check-office-launcher.py"), str(self.root)], check=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
