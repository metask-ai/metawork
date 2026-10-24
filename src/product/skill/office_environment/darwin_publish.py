"""Exclusive sibling directory publication; no rename/copy fallback."""
import ctypes
import errno
import os
from pathlib import Path
import sys


def publish(stage, final):
    if sys.platform != "darwin":
        raise RuntimeError("Darwin publisher requires macOS")
    stage, final = Path(stage), Path(final)
    if stage.parent.resolve() != final.parent.resolve() or stage.is_symlink() or not stage.is_dir():
        raise RuntimeError("Office stage must be an owned sibling directory")
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    parent = os.open(stage.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if rename(parent, os.fsencode(stage.name), parent, os.fsencode(final.name), 4):
            code = ctypes.get_errno()
            if code == errno.EEXIST:
                raise FileExistsError(code, "Office final path already exists", str(final))
            raise OSError(code, "Exclusive Office publication failed", str(final))
    finally:
        os.close(parent)
