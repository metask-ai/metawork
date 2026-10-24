---
name: xlsx
description: Create, read, edit, clean, format, calculate, and convert spreadsheets. Use for .xlsx, .csv, .tsv, Excel, formulas, charts, tabular data, financial models, and spreadsheet deliverables. Do not use for Word documents or Google Sheets API integration.
---

# XLSX creation, editing and analysis

## Execution environment

This is a complete built-in Skill. Its private environment may not be prepared yet. Only Windows x64 automatic preparation is supported.

Use the absolute resource entries `${CLAUDE_SKILL_DIR}/environment/prepare.cmd` and `${CLAUDE_SKILL_DIR}/environment/run.cmd` through the existing Shell, preserving Windows argument quoting. Never infer an executable from the parent of this resource directory.

First use `prepare.cmd python` or `prepare.cmd node` only to reuse an existing environment **after consent has already been obtained**, or use `run.cmd python ...` / `run.cmd node ...` to execute: run never downloads and reports a missing environment. Before first preparation, tell the user its purpose and `downloadTotals.python.totalBytes` or `downloadTotals.node.totalBytes` for the needed language from [environment inputs](environment/environment.json), then ask for agreement. Each total includes the interpreter and all locked library archives for a fresh preparation; index metadata, retries and transport overhead are extra, so describe it as an estimated network download. DOCX/PPTX creation and Python validation may need both environments; state the combined total when both are needed. Then call the fixed prepare entry for the needed language. No arbitrary URL, package list or version arguments are supported. Allow up to 30 minutes for interpreter download and 10 minutes for dependency installation; use the existing Shell background/output tools if its foreground limit is shorter. If preparation fails or is refused, explain the limitation and continue what is possible. Do not install globally or change user configuration. Consent is a conversation instruction; full_access has no additional product installation gate.

The prepared directories are shared under the user's LocalAppData/MetaWork/OfficeDependencies. Do not automatically update, rename, delete or repair completed environments. If an existing environment fails validation, report it as unavailable and give the exact directory printed by `prepare.cmd`. Explain manual recovery: stop every Task and external script using that directory, exit MetaWork, and confirm no consuming processes remain. Only then may the user explicitly choose to remove that one directory, reopen MetaWork and consent to preparing it again. Never remove the parent OfficeDependencies directory, other environments, Skill resources or documents. A successful rename does not prove that no process uses the environment; if consumers cannot be confirmed stopped, leave it untouched. Private dependencies are not an execution sandbox. Write task scripts, working copies and outputs in the Task workspace. Use `from office_archive import checked_copy` and load only the private checked path inside its context when passing an existing Office file to a library. Never overwrite the attachment original.

This edition cannot render documents, export PDF, accept revisions or recalculate formulas. Do not invent visual QA or calculation results. XLSX may request recalculation on open, but this does not calculate or populate caches now.

## Read, check and deliver

For bounded structured text: `run.cmd python "${CLAUDE_SKILL_DIR}/environment/read.py" input.docx new-content.json` (also XLSX/PPTX). For XML work, run the scripts under `scripts/office/` with `run.cmd python`, using new output directories. Reopen and inspect changed content and validate supported structures before delivery. Report unsupported features and checks not performed.

Call the Host tool `DeliverFile` with the actual Task Workspace-relative output path, e.g. `{"path":"results/report.docx"}`. This is a tool call, not a Shell command or text to print. Deliver only finished files requested by the user, not temporary XML, scripts or check output.

# Requirements for Outputs

## All Excel files

### Professional Font
- Use a consistent, professional font (e.g., Arial, Times New Roman) for all deliverables unless otherwise instructed by the user

### Formula checks
- Every Excel model MUST be delivered with ZERO formula errors (#REF!, #DIV/0!, #VALUE!, #N/A, #NAME?)

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
