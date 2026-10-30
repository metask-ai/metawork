---
name: xlsx
description: Create, read, edit, clean, and format spreadsheets with formulas and saved values. Use for .xlsx, .csv, .tsv, Excel, formulas, charts, tabular data, financial models, and spreadsheet deliverables. Do not use for Word documents or Google Sheets API integration.
---

# XLSX creation, editing and analysis

{{OFFICE_EXECUTION}}

## Creation, editing, verification and delivery

Read [the XLSX verification workflow](verification.md) before creating, editing or checking a workbook. Use the current XLSX Skill's `scripts/verify.py` through its private run entry. This XLSX workflow requires checks of the final saved candidate; structured text from `read.py` does not check formatting.

For a verification-only request, use the authorized existing workbook as the read-only candidate and preserve it. Record necessary unavailable checks with `unsupported` and run the checker to produce the structured incomplete result. A prose explanation can accompany that result; it does not replace the necessary-check mapping. Do not edit a workbook just to report that a required operation is unavailable.

1. Map the user's necessary contents, formatting and preservation requirements to explicit checks or unsupported items before generating. Derive numeric expectations independently from the raw input. Preserve originals and work on a new candidate.
2. Create or edit within the requested scope. Re-find totals by unique labels within their own tables, check expected coordinates, and cover every required data and total font/percentage range. A successful A1 check does not cover the rest of a workbook. For a matching CSV task, `examples/summary.py` is a runnable starting point.
3. Run `scripts/verify.py candidate.xlsx new-report.json --checks checks.json` and read the report. Distinguish a failed assertion, invalid specification, unsupported necessary check and execution failure. Resolve the actual cause within the task's scope. Do not drop requirements or change expectations to match a defective file.
4. After any edit, save and check again using a new report. Only report checks actually executed on the candidate's current bytes. Do not deliver an unfinished result as successful.
5. Use `DeliverFile` and compare its actual committed size and SHA-256 to the report's candidate identity. If they differ, retain the delivery fact and clearly state the check does not cover those delivered bytes; follow the workflow's mismatch handling. Base the final statement on delivery, verified scope and any outstanding requirements.

# Requirements for Outputs

## All Excel files

### Professional Font

- Use a consistent, professional font (e.g., Arial, Times New Roman) for all deliverables unless otherwise instructed by the user

### Formula checks

- Inspect formula strings, references and any saved error values (#REF!, #DIV/0!, #VALUE!, #N/A, #NAME?). This runtime cannot evaluate formulas; report absent or stale caches and do not claim a zero-error recalculation.

### Preserve Existing Templates (when updating templates)

- Study and EXACTLY match existing format, style, and conventions when modifying files
- Never impose standardized formatting on files with established patterns
- Existing template conventions ALWAYS override these guidelines

## Financial models

### Color Coding Standards

Unless otherwise stated by the user or existing template

#### Industry-Standard Color Conventions

- **Blue text (RGB: 0,0,255)**: Hardcoded inputs, and numbers users will change for scenarios
- **Black text (RGB: 0,0,0)**: ALL formulas and calculations
- **Green text (RGB: 0,128,0)**: Links pulling from other worksheets within same workbook
- **Red text (RGB: 255,0,0)**: External links to other files
- **Yellow background (RGB: 255,255,0)**: Key assumptions needing attention or cells that need to be updated

### Number Formatting Standards

#### Required Format Rules

- **Years**: Format as text strings (e.g., "2024" not "2,024")
- **Currency**: Use $#,##0 format; ALWAYS specify units in headers ("Revenue ($mm)")
- **Zeros**: Use number formatting to make all zeros "-", including percentages (e.g., "$#,##0;($#,##0);-")
- **Percentages**: Default to 0.0% format (one decimal)
- **Multiples**: Format as 0.0x for valuation multiples (EV/EBITDA, P/E)
- **Negative numbers**: Use parentheses (123) not minus -123

### Formula Construction Rules

#### Assumptions Placement

- Place ALL assumptions (growth rates, margins, multiples, etc.) in separate assumption cells
- Use cell references instead of hardcoded values in formulas
- Example: Use =B5*(1+$B$6) instead of =B5*1.05

#### Formula Error Prevention

- Verify all cell references are correct
- Check for off-by-one errors in ranges
- Ensure consistent formulas across all projection periods
- Test with edge cases (zero values, negative numbers)
- Verify no unintended circular references

#### Documentation Requirements for Hardcodes

- Comment or in cells beside (if end of table). Format: "Source: [System/Document], [Date], [Specific Reference], [URL if applicable]"
- Examples:
  - "Source: Company 10-K, FY2024, Page 45, Revenue Note, [SEC EDGAR URL]"
  - "Source: Company 10-Q, Q2 2025, Exhibit 99.1, [SEC EDGAR URL]"
  - "Source: Bloomberg Terminal, 8/15/2025, AAPL US Equity"
  - "Source: FactSet, 8/20/2025, Consensus Estimates Screen"

## Working with openpyxl

Use the fixed openpyxl library for data, formulas, styles, tables and supported charts. Pandas, NumPy and XlsxWriter are not part of this Skill.

```python
from pathlib import Path
from openpyxl import Workbook, load_workbook
from openpyxl.workbook.properties import CalcProperties
from office_archive import checked_copy

with checked_copy("input.xlsx") as checked:
    workbook = load_workbook(checked, data_only=False)
    sheet = workbook.active
    sheet["C2"] = "=SUM(A2:B2)"
    workbook.calculation = CalcProperties(fullCalcOnLoad=True, forceFullCalc=True)
    workbook.save("updated.xlsx")
    workbook.close()
```

For new workbooks start with Workbook(), save to a new output and reopen to check values, formula text and styles. Prefer formulas for derived values. Cached values may be absent or stale; data_only=True does not calculate. Bound dense iteration for sparse worksheets. Preserve templates and disclose features a library cannot retain; do not silently claim full fidelity.
