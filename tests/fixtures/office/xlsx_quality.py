"""Synthetic Office quality inputs; no production checker code lives here."""
from collections import defaultdict
from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill


RAW_ROWS = (
    ("o-1", "North", 100),
    ("o-2", "North", 200),
    ("o-3", "South", 150),
    ("o-4", "South", 200),
    ("o-2", "North", 200),  # Duplicate: keep the first order only.
    ("o-5", None, 75),      # Missing region: exclude from the summary.
    (None, "South", 90),    # Missing order: exclude from the summary.
)
TOTAL_LABEL = "Total"


def create_summary(destination: Path, rows=RAW_ROWS, *, faulty_totals=False):
    """Fixture authoring deliberately reproduces the last-data-row style bug."""
    book = Workbook()
    raw = book.active
    raw.title = "Input"
    raw.append(["Order", "Region", "Amount"])
    for row in rows:
        raw.append(row)
    data = book.create_sheet("Data")
    data.append(["Order", "Region", "Amount", "Share"])
    groups = defaultdict(int)
    seen = set()
    accepted = []
    for order, region, amount in rows:
        if not order or not region or order in seen:
            continue
        if type(amount) not in (int, float):
            continue
        seen.add(order)
        accepted.append((order, region, amount))
        groups[region] += amount
    amount_sum = sum(item[2] for item in accepted)
    for order, region, amount in accepted:
        data.append([order, region, amount, amount / amount_sum if amount_sum else 0])
    data.append([TOTAL_LABEL, None, amount_sum, 1 if amount_sum else 0])
    summary = book.create_sheet("Regions")
    summary.append(["Region", "Amount", "Share"])
    for region, amount in sorted(groups.items()):
        summary.append([region, amount, amount / amount_sum if amount_sum else 0])
    summary.append([TOTAL_LABEL, amount_sum, 1 if amount_sum else 0])
    for sheet, percent_column in ((data, 4), (summary, 3)):
        # Start with the data area. The total must receive its own formatting.
        for row in sheet.iter_rows(max_row=sheet.max_row - 1):
            for cell in row:
                cell.font = Font(name="Arial", size=11)
            row[percent_column - 1].number_format = "0.0%"
        total_row = sheet.max_row - 1 if faulty_totals else sheet.max_row
        for cell in sheet[total_row]:
            cell.font = Font(name="Arial", size=11, bold=True)
            cell.fill = PatternFill("solid", fgColor="FFDEEAF6")
        sheet.cell(total_row, percent_column).number_format = "0.0%"
    reference = book.create_sheet("Reference")
    reference["A1"] = "Preserve this source note"
    reference["H20"] = "Outside the edited range"
    reference["B2"] = "=1+2"
    book.save(destination)
    book.close()
