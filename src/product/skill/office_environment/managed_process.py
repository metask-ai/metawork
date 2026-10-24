"""Bounded child ownership for macOS preparation, including cancellation."""
import os
from pathlib import Path
import signal
import subprocess


def interrupted(unused_signal, unused_frame):
    raise KeyboardInterrupt("Office preparation cancelled")


def group_alive(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run(command, stage, timeout=600):
    # Persist uncertainty before spawning: even a coordinator crash must not
    # let its shell parent delete files that descendants might still consume.
    marker = Path(stage) / ".process-not-stopped"
    marker.touch()
    try:
        child = subprocess.Popen(command, start_new_session=True)
    except BaseException:
        # Popen can be interrupted after fork/exec but before returning its
        # handle. Without that handle we cannot prove the child was joined.
        # Keep the marker so the shell preserves this invocation's stage.
        raise
    try:
        status = child.wait(timeout=timeout)
        if group_alive(child.pid):
            raise RuntimeError("Office preparation descendants remain")
        marker.unlink()
        if status:
            raise subprocess.CalledProcessError(status, command)
    except BaseException:
        previous = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
        try:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=10)
            if not group_alive(child.pid):
                marker.unlink(missing_ok=True)
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)
        raise
