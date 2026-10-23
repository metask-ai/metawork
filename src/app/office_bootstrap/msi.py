"""Read-only extraction of the pinned Windows Office MSI.

Runs in an isolated bootstrap subprocess, never in the desktop process. Only
Windows' database reader and CAB decompressor are used: no MSI action, custom
action, installer service, registry registration, or installed Python is needed.
The caller owns the new destination and scratch directories through process join.
"""
import argparse
import ctypes
from ctypes import wintypes as w
import hashlib
import os
from pathlib import Path
import re
import stat
import time

MAX_FILES = 50000
MAX_BYTES = 3 * 1024**3
MAX_MEMBER = 512 * 1024**2
MAX_TABLE_BYTES = 16 * 1024**2
REPARSE_POINT = 0x400


def ordinary(path, kind):
    info = path.lstat()
    if info.st_file_attributes & REPARSE_POINT or not kind(info.st_mode):
        raise ValueError("MSI input or extraction directory is not an ordinary entry")
    return info


def component(value):
    if (not value or len(value) > 255 or value in (".", "..") or
            value.endswith((" ", ".")) or any(ord(c) < 32 or c in '\\/:*?"<>|' for c in value) or
            re.fullmatch(r"(?:con|prn|aux|nul|com[1-9]|lpt[1-9])", value.split(".")[0], re.I)):
        raise ValueError("Unsafe MSI path component")
    return value


def source_name(value):
    return value.split("|", 1)[-1]


def directory_paths(rows):
    by_id = {}
    for identity, parent, name in rows:
        if identity in by_id:
            raise ValueError("Duplicate MSI directory")
        by_id[identity] = (parent, name)
    paths = {}

    def resolve(identity, visiting=()):
        if identity in paths:
            return paths[identity]
        if identity in visiting or len(visiting) >= 32 or identity not in by_id:
            raise ValueError("Cyclic or missing MSI directory")
        parent, value = by_id[identity]
        if not parent or parent == identity:
            if identity != "TARGETDIR":
                raise ValueError("Unexpected MSI root directory")
            result = ()
        else:
            # Administrative images use source directory names, not the target
            # system-folder properties. All names remain below the owned root.
            name = source_name(value.split(":", 1)[-1])
            result = resolve(parent, visiting + (identity,))
            if name != ".":
                result += (component(name),)
        if len("/".join(result)) > 1024:
            raise ValueError("MSI directory path exceeds budget")
        paths[identity] = result
        return result

    for identity in by_id:
        resolve(identity)
    return paths


class Database:
    def __init__(self, filename):
        self.dll = ctypes.WinDLL("msi.dll", winmode=0x800)
        functions = {
            "MsiOpenDatabaseW": [w.LPCWSTR, w.LPCWSTR, ctypes.POINTER(w.UINT)],
            "MsiDatabaseOpenViewW": [w.UINT, w.LPCWSTR, ctypes.POINTER(w.UINT)],
            "MsiViewExecute": [w.UINT, w.UINT],
            "MsiViewFetch": [w.UINT, ctypes.POINTER(w.UINT)],
            "MsiRecordGetStringW": [w.UINT, w.UINT, w.LPWSTR, ctypes.POINTER(w.DWORD)],
            "MsiRecordReadStream": [w.UINT, w.UINT, ctypes.c_void_p, ctypes.POINTER(w.DWORD)],
            "MsiRecordSetStringW": [w.UINT, w.UINT, w.LPCWSTR],
            "MsiCloseHandle": [w.UINT],
            "MsiCreateRecord": [w.UINT],
        }
        for name, args in functions.items():
            function = getattr(self.dll, name)
            function.argtypes = args
            function.restype = w.UINT
        self.handle = w.UINT()
        self.check(self.dll.MsiOpenDatabaseW(str(filename), None, ctypes.byref(self.handle)))
        self.table_bytes = 0
        self.deadline = time.monotonic() + 180

    @staticmethod
    def check(code):
        if code:
            raise OSError(code, "Office MSI database read failed")

    def close(self):
        self.dll.MsiCloseHandle(self.handle)

    def view(self, sql):
        result = w.UINT()
        self.check(self.dll.MsiDatabaseOpenViewW(self.handle, sql, ctypes.byref(result)))
        return result

    def text(self, record, column):
        buffer = ctypes.create_unicode_buffer(1025)
        size = w.DWORD(len(buffer))
        self.check(self.dll.MsiRecordGetStringW(record, column, buffer, ctypes.byref(size)))
        self.table_bytes += size.value * 2
        if self.table_bytes > MAX_TABLE_BYTES:
            raise ValueError("Office MSI table budget exceeded")
        return buffer.value

    def rows(self, sql, columns):
        view = self.view(sql)
        try:
            self.check(self.dll.MsiViewExecute(view, 0))
            result = []
            while True:
                record = w.UINT()
                code = self.dll.MsiViewFetch(view, ctypes.byref(record))
                if code == 259:
                    return result
                self.check(code)
                try:
                    if len(result) >= MAX_FILES or time.monotonic() > self.deadline:
                        raise ValueError("Office MSI table budget exceeded")
                    result.append(tuple(self.text(record, i + 1) for i in range(columns)))
                finally:
                    self.dll.MsiCloseHandle(record)
        finally:
            self.dll.MsiCloseHandle(view)

    def cabinet(self, name, destination, maximum):
        view = self.view("SELECT `Data` FROM `_Streams` WHERE `Name` = ?")
        parameter = self.dll.MsiCreateRecord(1)
        if not parameter:
            self.dll.MsiCloseHandle(view)
            raise ValueError("Cannot allocate MSI stream parameter")
        record = w.UINT()
        try:
            self.check(self.dll.MsiRecordSetStringW(parameter, 1, name))
            self.check(self.dll.MsiViewExecute(view, parameter))
            self.check(self.dll.MsiViewFetch(view, ctypes.byref(record)))
            total = 0
            buffer = ctypes.create_string_buffer(65536)
            with destination.open("xb") as output:
                while True:
                    size = w.DWORD(len(buffer))
                    self.check(self.dll.MsiRecordReadStream(record, 1, buffer, ctypes.byref(size)))
                    if not size.value:
                        break
                    total += size.value
                    if total > maximum or time.monotonic() > self.deadline:
                        raise ValueError("Office MSI cabinet budget exceeded")
                    output.write(buffer.raw[:size.value])
            if not total:
                raise ValueError("Office MSI cabinet is empty")
        finally:
            if record.value:
                self.dll.MsiCloseHandle(record)
            self.dll.MsiCloseHandle(parameter)
            self.dll.MsiCloseHandle(view)


def extract_cabinet(cabinet, files, destination, scratch):
    class FileInfo(ctypes.Structure):
        _fields_ = [("name", w.LPCWSTR), ("size", w.DWORD), ("error", w.DWORD),
                    ("date", w.WORD), ("time", w.WORD), ("attributes", w.WORD),
                    ("target", w.WCHAR * 260)]

    class FilePaths(ctypes.Structure):
        _fields_ = [("target", w.LPCWSTR), ("source", w.LPCWSTR), ("error", w.UINT), ("flags", w.DWORD)]

    setup = ctypes.WinDLL("setupapi.dll", winmode=0x800, use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(w.UINT, ctypes.c_void_p, w.UINT, ctypes.c_size_t, ctypes.c_size_t)
    setup.SetupIterateCabinetW.argtypes = [w.LPCWSTR, w.DWORD, callback_type, ctypes.c_void_p]
    setup.SetupIterateCabinetW.restype = w.BOOL
    seen = set()
    failure = []
    pending = None
    started = time.monotonic()

    @callback_type
    def callback(_, notification, first, second):
        nonlocal pending
        try:
            if time.monotonic() - started > 180:
                raise ValueError("Office MSI extraction deadline exceeded")
            if notification == 0x10:  # SPFILENOTIFY_CABINETINFO
                return 0
            if notification == 0x11:  # SPFILENOTIFY_FILEINCABINET
                info = ctypes.cast(first, ctypes.POINTER(FileInfo)).contents
                name = info.name.casefold()
                if name not in files or name in seen or pending is not None:
                    raise ValueError("Unknown, duplicate or interleaved MSI cabinet member")
                target, size = files[name]
                if info.size != size or info.attributes & 0x10:
                    raise ValueError("MSI cabinet member differs from its table")
                if target is None:
                    seen.add(name)
                    return 2  # FILEOP_SKIP: explicitly excluded source member
                # A fixed short relative filename avoids SetupAPI's MAX_PATH
                # field without changing the desktop process working directory.
                temporary = f"member-{len(seen):05d}.part"
                if Path(temporary).exists():
                    raise ValueError("MSI cabinet scratch collision")
                info.target = temporary
                pending = (name, temporary, target, size)
                return 1  # FILEOP_DOIT
            if notification == 0x13:  # SPFILENOTIFY_FILEEXTRACTED
                info = ctypes.cast(first, ctypes.POINTER(FilePaths)).contents
                if info.error or pending is None:
                    raise ValueError("MSI cabinet extraction failed")
                name, temporary, parts, size = pending
                source = scratch / temporary
                if ordinary(source, stat.S_ISREG).st_size != size:
                    raise ValueError("Extracted MSI member differs from its table")
                parent = destination
                for part in parts[:-1]:
                    parent /= part
                    parent.mkdir(exist_ok=True)
                    ordinary(parent, stat.S_ISDIR)
                target = parent / parts[-1]
                if target.exists() or target.is_symlink():
                    raise ValueError("MSI destination collision")
                source.rename(target)
                seen.add(name)
                pending = None
                return 0
            # Includes NEEDNEWCABINET: never read another path or download media.
            raise ValueError("Unsupported MSI cabinet notification")
        except BaseException as error:
            failure.append(error)
            return 0 if notification == 0x11 else 1223

    previous = Path.cwd()
    try:
        os.chdir(scratch)
        succeeded = setup.SetupIterateCabinetW(str(cabinet), 0, callback, None)
    finally:
        os.chdir(previous)
    if failure:
        raise failure[0]
    if not succeeded or pending is not None or len(seen) != len(files):
        raise ValueError("Office MSI cabinet did not produce the complete file set")


def extract(msi, destination, scratch, expected_bytes, expected_sha256, excluded_files=()):
    if os.name != "nt":
        raise ValueError("Office MSI bootstrap requires Windows")
    for path in (msi, destination, scratch):
        if not path.is_absolute():
            raise ValueError("Office MSI bootstrap requires absolute paths")
    if expected_bytes <= 0 or expected_bytes > MAX_MEMBER or not re.fullmatch(r"[a-f0-9]{64}", expected_sha256):
        raise ValueError("Office MSI bootstrap requires a fixed source identity")
    excluded = {component(name).casefold() for name in excluded_files}
    if len(excluded) != len(excluded_files) or len(excluded) > 32:
        raise ValueError("Invalid explicit MSI source exclusions")
    for path in (msi.parent, destination.parent, scratch):
        for ancestor in (path, *path.parents):
            ordinary(ancestor, stat.S_ISDIR)
    ordinary(msi, stat.S_ISREG)
    kernel = ctypes.WinDLL("kernel32.dll", winmode=0x800, use_last_error=True)
    kernel.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p, w.DWORD, w.DWORD, w.HANDLE]
    kernel.CreateFileW.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    # Deny writers and replacement while the OS database reader opens this same
    # pinned pathname. Never execute an action from the downloaded package.
    locked = kernel.CreateFileW(str(msi), 0x80000000, 1, None, 3, 0x00200000, None)
    if locked in (None, ctypes.c_void_p(-1).value):
        raise OSError(ctypes.get_last_error(), "Cannot lock Office MSI input")
    try:
        with msi.open("rb") as source:
            digest = hashlib.sha256()
            if os.fstat(source.fileno()).st_size != expected_bytes:
                raise ValueError("Office MSI bytes differ from the pinned source")
            while chunk := source.read(65536):
                digest.update(chunk)
            if digest.hexdigest() != expected_sha256:
                raise ValueError("Office MSI bytes differ from the pinned source")
        database = Database(msi)
        try:
            directories = directory_paths(database.rows("SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`", 3))
            components = dict(database.rows("SELECT `Component`,`Directory_` FROM `Component`", 2))
            rows = database.rows("SELECT `File`,`Component_`,`FileName`,`FileSize` FROM `File`", 4)
            files, targets, total = {}, set(), 0
            for identity, owner, name, amount in rows:
                component(identity)
                parts = directories[components[owner]] + (component(source_name(name)),)
                target = "/".join(parts).casefold()
                size = int(amount)
                ignored = identity.casefold() in excluded
                if (not ignored and target in targets) or identity.casefold() in files or size < 0 or size > MAX_MEMBER or len(target) > 1280:
                    raise ValueError("Office MSI file identity or size is invalid")
                total += size
                if total > MAX_BYTES:
                    raise ValueError("Office MSI expansion exceeds budget")
                files[identity.casefold()] = (None if ignored else parts, size)
                if not ignored:
                    targets.add(target)
            if not excluded.issubset(files):
                raise ValueError("Pinned MSI source exclusions are absent")
            media = database.rows("SELECT `Cabinet` FROM `Media`", 1)
            if len(media) != 1 or not media[0][0].startswith("#") or not files:
                raise ValueError("Office MSI requires one embedded cabinet")
            name = component(media[0][0][1:])
            cabinet = scratch / "payload.cab"
            database.cabinet(name, cabinet, expected_bytes)
        finally:
            database.close()
        destination.mkdir()
        extract_cabinet(cabinet, files, destination, scratch)
        cabinet.unlink()
        return {"files": len(files) - len(excluded), "excluded": len(excluded), "bytes": sum(size for parts, size in files.values() if parts is not None)}
    finally:
        kernel.CloseHandle(locked)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("msi", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("scratch", type=Path)
    parser.add_argument("expected_bytes", type=int)
    parser.add_argument("expected_sha256")
    parser.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args()
    print(extract(args.msi, args.destination, args.scratch, args.expected_bytes, args.expected_sha256, args.exclude))
