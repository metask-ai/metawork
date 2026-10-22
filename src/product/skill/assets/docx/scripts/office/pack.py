"""Pack a directory into a DOCX, PPTX, or XLSX file.

Validates with auto-repair, condenses XML formatting, and creates the Office file.

Usage:
    python pack.py <input_directory> <output_file> [--original <file>] [--validate true|false]

Examples:
    python pack.py unpacked/ output.docx --original input.docx
    python pack.py unpacked/ output.pptx --validate false
"""

import argparse
import sys
import os
import stat
from contextlib import ExitStack
import tempfile
import zipfile
from pathlib import Path

import defusedxml.minidom

from archive import ArchiveError, CHUNK, DEFAULT_LIMITS, check_archive, checked_copy

from validators import DOCXSchemaValidator, PPTXSchemaValidator, RedliningValidator

def pack(
    input_directory: str,
    output_file: str,
    original_file: str | None = None,
    validate: bool = True,
    infer_author_func=None,
) -> tuple[None, str]:
    input_dir = Path(input_directory)
    output_path = Path(output_file).absolute()
    suffix = output_path.suffix.lower()

    if not input_dir.is_dir() or input_dir.is_symlink():
        return None, f"Error: {input_dir} must be a regular directory"
    if suffix not in {".docx", ".pptx", ".xlsx"}:
        return None, f"Error: {output_file} must be a .docx, .pptx, or .xlsx file"
    if output_path.resolve().is_relative_to(input_dir.resolve()) or output_path.is_symlink():
        return None, "Error: Output must be outside the input tree and cannot be a link"
    if original_file:
        original_path = Path(original_file)
        if not original_path.is_file() or original_path.is_symlink():
            return None, f"Error: Original file {original_file} is missing or is not a regular file"
        if (output_path.resolve() == original_path.resolve() or
                (output_path.exists() and os.path.samefile(output_path, original_path))):
            return None, "Error: Output cannot overwrite the original file"

    try:
        with ExitStack() as resources:
            original_path = resources.enter_context(checked_copy(original_file)) if original_file else None
            temp_dir = resources.enter_context(tempfile.TemporaryDirectory(prefix="metawork-office-pack-"))
            temp_content_dir = Path(temp_dir) / "content"
            _copy_content(input_dir, temp_content_dir)

            for pattern in ["*.xml", "*.rels"]:
                for xml_file in temp_content_dir.rglob(pattern):
                    _condense_xml(xml_file)

            if validate:
                success, output = _run_validation(
                    temp_content_dir, original_path, suffix, infer_author_func
                )
                if output:
                    print(output)
                if not success:
                    return None, f"Error: Validation failed for {input_dir}"

            output_path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=output_path.parent, suffix=suffix, delete=False) as staged:
                staged_path = Path(staged.name)
            try:
                with zipfile.ZipFile(staged_path, "w", zipfile.ZIP_DEFLATED) as zf:
                    for f in sorted(temp_content_dir.rglob("*")):
                        if f.is_file():
                            zf.write(f, f.relative_to(temp_content_dir))
                check_archive(staged_path)
                os.replace(staged_path, output_path)
            finally:
                staged_path.unlink(missing_ok=True)
    except Exception as error:
        return None, f"Error: {error}"
    return None, f"Successfully packed {input_dir} to {output_file}"


def _copy_content(source, destination):
    """Bound the actual private copy before any parser or repair consumes it."""
    limits = DEFAULT_LIMITS
    destination.mkdir()
    total, members = 0, 0
    for directory, dirs, files in os.walk(source, followlinks=False):
        relative_dir = Path(directory).relative_to(source)
        for name in dirs + files:
            original = Path(directory) / name
            relative = relative_dir / name
            before = original.lstat()
            members += 1
            if (members > limits.members or len(relative.parts) > limits.depth or
                    len(relative.as_posix().encode("utf-8")) > limits.path_bytes):
                raise ArchiveError("Office work-copy path or member budget exceeded")
            target = destination / relative
            if stat.S_ISDIR(before.st_mode):
                target.mkdir()
                continue
            if not stat.S_ISREG(before.st_mode) or before.st_size > limits.member_bytes:
                raise ArchiveError("Office work copy rejects links, special files and oversized members")
            flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
            with os.fdopen(os.open(original, flags), "rb") as input_file, target.open("xb") as output:
                opened = os.fstat(input_file.fileno())
                if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                    raise ArchiveError("Office work-copy input changed")
                size = 0
                while chunk := input_file.read(CHUNK):
                    size += len(chunk)
                    total += len(chunk)
                    if size > limits.member_bytes or total > limits.total_bytes:
                        raise ArchiveError("Actual Office work-copy byte budget exceeded")
                    output.write(chunk)
                after = os.fstat(input_file.fileno())
                if (after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                    raise ArchiveError("Office work-copy input changed")


def _run_validation(
    unpacked_dir: Path,
    original_file: Path | None,
    suffix: str,
    infer_author_func=None,
) -> tuple[bool, str | None]:
    output_lines = []
    validators = []

    if suffix == ".docx":
        author = "Claude"
        if infer_author_func and original_file:
            try:
                author = infer_author_func(unpacked_dir, original_file)
            except ArchiveError:
                raise
            except ValueError as e:
                print(f"Warning: {e} Using default author 'Claude'.", file=sys.stderr)

        validators = [
            DOCXSchemaValidator(unpacked_dir, original_file),
        ]
        if original_file:
            validators.append(RedliningValidator(unpacked_dir, original_file, author=author))
    elif suffix == ".pptx":
        validators = [PPTXSchemaValidator(unpacked_dir, original_file)]

    if not validators:
        return True, None

    total_repairs = sum(v.repair() for v in validators)
    if total_repairs:
        output_lines.append(f"Auto-repaired {total_repairs} issue(s)")

    success = all(v.validate() for v in validators)

    if success:
        output_lines.append("All validations PASSED!")

    return success, "\n".join(output_lines) if output_lines else None


def _condense_xml(xml_file: Path) -> None:
    try:
        with open(xml_file, encoding="utf-8") as f:
            dom = defusedxml.minidom.parse(f)

        for element in dom.getElementsByTagName("*"):
            if element.tagName.endswith(":t"):
                continue

            for child in list(element.childNodes):
                if (
                    child.nodeType == child.TEXT_NODE
                    and child.nodeValue
                    and child.nodeValue.strip() == ""
                ) or child.nodeType == child.COMMENT_NODE:
                    element.removeChild(child)

        xml_file.write_bytes(dom.toxml(encoding="UTF-8"))
    except Exception as e:
        print(f"ERROR: Failed to parse {xml_file.name}: {e}", file=sys.stderr)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Pack a directory into a DOCX, PPTX, or XLSX file"
    )
    parser.add_argument("input_directory", help="Unpacked Office document directory")
    parser.add_argument("output_file", help="Output Office file (.docx/.pptx/.xlsx)")
    parser.add_argument(
        "--original",
        help="Original file for validation comparison",
    )
    parser.add_argument(
        "--validate",
        type=lambda x: x.lower() == "true",
        default=True,
        metavar="true|false",
        help="Run validation with auto-repair (default: true)",
    )
    args = parser.parse_args()

    _, message = pack(
        args.input_directory,
        args.output_file,
        original_file=args.original,
        validate=args.validate,
    )
    print(message)

    if "Error" in message:
        sys.exit(1)
