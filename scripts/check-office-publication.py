"""macOS exclusive publication and owned-process cancellation regression."""
import concurrent.futures
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

if sys.platform != "darwin":
    raise SystemExit("This regression requires native macOS")
RESOURCES = Path(__file__).resolve().parents[1] / "src/product/skill/office_environment"
sys.path.insert(0, str(RESOURCES))
from darwin_publish import publish
import managed_process


class Publication(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="office publish 中文 ' ")
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_existing_objects_are_preserved(self):
        stage, final = self.root / "stage", self.root / "final"
        stage.mkdir()
        for kind in ("empty-directory", "file", "symlink"):
            if kind == "empty-directory":
                final.mkdir()
            elif kind == "file":
                final.write_text("preserved")
            else:
                final.symlink_to(stage, target_is_directory=True)
            with self.assertRaises(FileExistsError):
                publish(stage, final)
            self.assertTrue(stage.is_dir())
            if kind == "empty-directory":
                self.assertEqual(list(final.iterdir()), [])
                final.rmdir()
            else:
                if kind == "file":
                    self.assertEqual(final.read_text(), "preserved")
                else:
                    self.assertEqual(final.readlink(), stage)
                final.unlink()

    def test_concurrent_winner_is_a_whole_directory(self):
        final = self.root / "final"
        stages = [self.root / str(i) for i in range(2)]
        for i, stage in enumerate(stages):
            stage.mkdir()
            (stage / "payload").write_text(str(i))
        def race(stage):
            try:
                publish(stage, final)
                return True
            except FileExistsError:
                return False
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            winners = list(pool.map(race, stages))
        self.assertEqual(sum(winners), 1)
        self.assertEqual((final / "payload").read_text(), str(winners.index(True)))

    def test_cancellation_joins_owned_child_before_cleanup(self):
        stage = self.root / "stage"
        stage.mkdir()
        pid_file = self.root / "pid"
        runner = '''import sys,signal
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from managed_process import run,interrupted
signal.signal(signal.SIGTERM,interrupted)
run([sys.executable,"-c","import os,time,sys;from pathlib import Path;Path(sys.argv[1]).write_text(str(os.getpid()));time.sleep(120)",sys.argv[3]],Path(sys.argv[2]))
'''
        child = subprocess.Popen([sys.executable, "-B", "-c", runner, str(RESOURCES), str(stage), str(pid_file)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while not pid_file.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pid_file.exists())
            owned = int(pid_file.read_text())
            self.assertTrue((stage / ".process-not-stopped").exists())
            child.send_signal(signal.SIGTERM)
            self.assertNotEqual(child.wait(timeout=25), 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(owned, 0)
            self.assertFalse((stage / ".process-not-stopped").exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_interrupted_spawn_preserves_stage_uncertainty(self):
        stage = self.root / "stage"
        stage.mkdir()
        spawn = subprocess.Popen
        children = []

        def interrupted_spawn(*args, **kwargs):
            children.append(spawn(*args, **kwargs))
            raise KeyboardInterrupt("cancelled before Popen returned its handle")

        try:
            with patch.object(managed_process.subprocess, "Popen", interrupted_spawn):
                with self.assertRaises(KeyboardInterrupt):
                    managed_process.run([sys.executable, "-B", "-c", "import time;time.sleep(120)"], stage)
            self.assertEqual(len(children), 1)
            self.assertIsNone(children[0].poll())
            self.assertTrue((stage / ".process-not-stopped").is_file())
        finally:
            for child in children:
                child.terminate()
                child.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
