"""
Excel Formula Recalculation Script
Recalculates all formulas in an Excel file using LibreOffice
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

from office.archive import checked_copy
from pathlib import Path

from office.soffice import get_soffice_env

from openpyxl import load_workbook

from office.formulas import _formulas, _check_formula_caches, _summary


def _identity(path):
    value = path.lstat()
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def recalc(filename, timeout=30):
    source = Path(filename).absolute()
    if source.suffix.lower() != ".xlsx":
        return {"error": "Formula recalculation accepts .xlsx files only"}
    if timeout <= 0:
        return {"error": "Timeout must be positive"}

    try:
        identity = _identity(source)
        with checked_copy(source) as input_copy, tempfile.TemporaryDirectory(prefix="metawork-xlsx-") as directory:
            expected_formulas = _formulas(input_copy)
            scratch = Path(directory)
            output = scratch / "output"
            output.mkdir()
            profile = (scratch / "profile").as_uri()
            result = subprocess.run(
                ["soffice", f"-env:UserInstallation={profile}", "--headless", "--norestore",
                 "--convert-to", "xlsx", "--outdir", str(output), str(input_copy)],
                capture_output=True, text=True, timeout=timeout, env=get_soffice_env(),
            )
            converted = output / input_copy.name
            if result.returncode != 0 or not converted.is_file():
                return {"error": result.stderr.strip() or "LibreOffice did not produce a recalculated workbook"}
            with checked_copy(converted) as checked_output:
                with tempfile.NamedTemporaryFile(dir=source.parent, suffix=".xlsx", delete=False) as staged:
                    staged_path = Path(staged.name)
                try:
                    shutil.copyfile(checked_output, staged_path)
                    if _formulas(staged_path) != expected_formulas:
                        raise ValueError("Recalculation changed or removed workbook formulas")
                    _check_formula_caches(staged_path)
                    summary = _summary(staged_path, len(expected_formulas))
                    if _identity(source) != identity:
                        raise ValueError("Source workbook changed during recalculation; result not published")
                    os.replace(staged_path, source)
                    return summary
                finally:
                    staged_path.unlink(missing_ok=True)
    except subprocess.TimeoutExpired:
        return {"error": f"LibreOffice recalculation timed out after {timeout} seconds"}
    except Exception as error:
        return {"error": str(error)}


def main():
    if len(sys.argv) < 2:
        print("Usage: python recalc.py <excel_file> [timeout_seconds]")
        print("\nRecalculates all formulas in an Excel file using LibreOffice")
        print("\nReturns JSON with error details:")
        print("  - status: 'success' or 'errors_found'")
        print("  - total_errors: Total number of Excel errors found")
        print("  - total_formulas: Number of formulas in the file")
        print("  - error_summary: Breakdown by error type with locations")
        print("    - #VALUE!, #DIV/0!, #REF!, #NAME?, #NULL!, #NUM!, #N/A")
        sys.exit(1)

    filename = sys.argv[1]
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 30

    result = recalc(filename, timeout)
    print(json.dumps(result, indent=2))
    if "error" in result or result.get("status") != "success":
        sys.exit(1)


if __name__ == "__main__":
    main()
