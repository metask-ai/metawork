"""Windows Office component entry: argv, physical descendants and failure exit.

Takes a prepared fixture root containing bin/office.exe and python/. The suite
copies those into its own workspace scratch; it never edits the supplied root.
"""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

if os.name != "nt":
    raise SystemExit("Office launcher qualification requires Windows")
PREPARED = Path(sys.argv.pop(1)).resolve()
ROOT = Path(__file__).resolve().parents[1]

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]


class OfficeLauncher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = ROOT / ".zig-cache/office-launcher-regression"
        base.mkdir(parents=True, exist_ok=True)
        cls.scratch = tempfile.TemporaryDirectory(prefix="Office 路径 ", dir=base)
        cls.root = Path(cls.scratch.name)
        shutil.copytree(PREPARED / "python", cls.root / "python")
        (cls.root / "bin").mkdir()
        shutil.copyfile(PREPARED / "bin/office.exe", cls.root / "bin/office.exe")
        (cls.root / "tools").mkdir()
        (cls.root / "engine/program").mkdir(parents=True)
        cls.script = cls.root / "tools/office.py"
        cls.exe = cls.root / "bin/office.exe"

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def run_script(self, source, arguments=()):
        self.script.write_text(source, encoding="utf-8")
        return subprocess.run([str(self.exe), *arguments], capture_output=True, text=True,
                              encoding="utf-8", timeout=15)

    def start_tree(self, orphan=False):
        self.script.write_text('''import json,os,subprocess,sys,time
child=subprocess.Popen([sys.executable,'-I','-S','-c','import time;time.sleep(60)'],
    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print(json.dumps({'python':os.getpid(),'descendant':child.pid}),flush=True)
''' + ("" if orphan else "time.sleep(60)\n"), encoding="utf-8")
        process = subprocess.Popen([str(self.exe)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8")
        self.addCleanup(self.stop, process)
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(process.stdout.readline()), daemon=True).start()
        line = lines.get(timeout=10)
        self.assertTrue(line, process.stderr.read() if process.poll() is not None else "No startup receipt")
        return process, json.loads(line)

    def stop(self, process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def handle(self, pid, terminate=False):
        handle = kernel.OpenProcess(0x100000 | 0x1000 | (1 if terminate else 0), False, pid)
        self.assertTrue(handle, ctypes.get_last_error())
        self.addCleanup(kernel.CloseHandle, handle)
        return handle

    def test_unicode_spaces_quotes_backslashes_and_shell_metacharacters_roundtrip(self):
        arguments = ["", "plain", "space value", 'quote"value', "trailing\\", 'slash\\"quote',
                     "中文路径", "& literal %PATH% !", "\\" * 80 + '"' + "\\" * 80]
        result = self.run_script("import sys,json;print(json.dumps(sys.argv[1:],ensure_ascii=True))", arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), arguments)

    def test_python_failure_is_the_entry_exit_status(self):
        result = self.run_script("raise SystemExit(7)")
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_component_environment_does_not_modify_the_invoker(self):
        original = os.environ.get("PATH")
        result = self.run_script("import os,json;print(json.dumps(os.environ['PATH']))")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout).startswith(str(self.root / "engine/program") + ";"))
        self.assertEqual(os.environ.get("PATH"), original)

    def test_killed_entry_terminates_python_and_its_descendant(self):
        process, pids = self.start_tree()
        handles = [self.handle(pid) for pid in pids.values()]
        for handle in handles:
            self.assertEqual(kernel.WaitForSingleObject(handle, 0), 258)
        process.kill()
        process.wait(timeout=10)
        for handle in handles:
            self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0)

    def test_killed_outer_python_cannot_leave_a_successful_entry_or_live_descendant(self):
        process, pids = self.start_tree()
        python = self.handle(pids["python"], terminate=True)
        descendant = self.handle(pids["descendant"])
        self.assertTrue(kernel.TerminateProcess(python, 1))
        process.wait(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(kernel.WaitForSingleObject(descendant, 5000), 0)

    def test_python_returning_with_an_orphan_is_failure_and_cleans_it(self):
        process, pids = self.start_tree(orphan=True)
        descendant = self.handle(pids["descendant"])
        process.wait(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(kernel.WaitForSingleObject(descendant, 5000), 0)


if __name__ == "__main__":
    unittest.main()
