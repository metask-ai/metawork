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
from pathlib import Path

from office.soffice import get_soffice_env

from openpyxl import load_workbook

def recalc(filename, timeout=30):
    if not Path(filename).exists():
        return {"error": f"File {filename} does not exist"}
    source = Path(filename).resolve()
    if source.suffix.lower() != ".xlsx":
        return {"error": "Formula recalculation accepts .xlsx files only"}
    if timeout <= 0:
        return {"error": "Timeout must be positive"}

    # Conversion into a distinct output directory forces Calc to load and
    # save the workbook. The private profile avoids changing the user's
    # LibreOffice configuration or attaching to an existing instance.
    try:
        with tempfile.TemporaryDirectory(prefix="metawork-xlsx-") as directory:
            scratch = Path(directory)
            output = scratch / "output"
            output.mkdir()
            profile = (scratch / "profile").as_uri()
            result = subprocess.run(
                ["soffice", f"-env:UserInstallation={profile}", "--headless", "--norestore",
                 "--convert-to", "xlsx", "--outdir", str(output), str(source)],
                capture_output=True, text=True, timeout=timeout, env=get_soffice_env(),
            )
            converted = output / (source.stem + ".xlsx")
            if result.returncode != 0 or not converted.is_file():
                return {"error": result.stderr.strip() or "LibreOffice did not produce a recalculated workbook"}
            with tempfile.NamedTemporaryFile(dir=source.parent, suffix=".xlsx", delete=False) as staged:
                staged_path = Path(staged.name)
            try:
                shutil.copyfile(converted, staged_path)
                check = load_workbook(staged_path, data_only=True)
                check.close()
                os.replace(staged_path, source)
            finally:
                staged_path.unlink(missing_ok=True)
    except subprocess.TimeoutExpired:
        return {"error": f"LibreOffice recalculation timed out after {timeout} seconds"}
    except Exception as error:
        return {"error": str(error)}

    try:
        wb = load_workbook(filename, data_only=True)

        excel_errors = [
            "#VALUE!",
            "#DIV/0!",
            "#REF!",
            "#NAME?",
            "#NULL!",
            "#NUM!",
            "#N/A",
        ]
        error_details = {err: [] for err in excel_errors}
        total_errors = 0

        for sheet_name in wb.sheetnames:
            ws = wb[sheet_name]
            for row in ws.iter_rows():
                for cell in row:
                    if cell.value is not None and isinstance(cell.value, str):
                        for err in excel_errors:
                            if err in cell.value:
                                location = f"{sheet_name}!{cell.coordinate}"
                                error_details[err].append(location)
                                total_errors += 1
                                break

        wb.close()

        result = {
            "status": "success" if total_errors == 0 else "errors_found",
            "total_errors": total_errors,
            "error_summary": {},
        }

        for err_type, locations in error_details.items():
            if locations:
                result["error_summary"][err_type] = {
                    "count": len(locations),
                    "locations": locations[:20],
                }

        wb_formulas = load_workbook(filename, data_only=False)
        formula_count = 0
        for sheet_name in wb_formulas.sheetnames:
            ws = wb_formulas[sheet_name]
            for row in ws.iter_rows():
                for cell in row:
                    if (
                        cell.value
                        and isinstance(cell.value, str)
                        and cell.value.startswith("=")
                    ):
                        formula_count += 1
        wb_formulas.close()

        result["total_formulas"] = formula_count

        return result

    except Exception as e:
        return {"error": str(e)}


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
