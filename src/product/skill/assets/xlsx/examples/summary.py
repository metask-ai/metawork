"""Example: bounded CSV cleaning and summary, saved to a new XLSX.

Input header: Order,Region,Amount (UTF-8 CSV, optional BOM).
Rules: trim order/region, exclude missing order/region, retain first complete
order, require finite amounts with at most two decimal places and amounts/groups/
total bounded to 1e12, zero total means zero shares. Confirm these rules match
the user's task before using this example.
Run via the XLSX Skill's private Python. No installation or input modification.
"""
import argparse
import csv
from decimal import Decimal, InvalidOperation
import io
import json
from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill


class SummaryInputError(ValueError):
    """Only fixed, content-free input explanations may be printed."""


def create(source, destination, font):
    if not 1 <= len(font) <= 128:
        raise SummaryInputError("Font name budget exceeded")
    with source.open("rb") as file:
        raw = file.read(256 * 1024 + 1)
    if len(raw) > 256 * 1024:
        raise SummaryInputError("CSV byte budget exceeded")
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8-sig"), newline="")))
    if not rows or rows[0] != ["Order", "Region", "Amount"]:
        raise SummaryInputError("Expected Order,Region,Amount header")
    if len(rows) > 8001 or any(len(row) != 3 for row in rows):
        raise SummaryInputError("CSV row shape/budget exceeded")
    clean, groups, seen = [], {}, set()
    for order, region, amount_text in rows[1:]:
        order, region = order.strip(), region.strip()
        if not order or not region or order in seen:
            continue
        try:
            amount = Decimal(amount_text)
        except InvalidOperation as error:
            raise SummaryInputError("Invalid amount") from error
        if not amount.is_finite() or abs(amount) > Decimal("1000000000000") or amount.as_tuple().exponent < -2:
            raise SummaryInputError("Amount outside the example's precision/range")
        clean.append((order, region, amount))
        seen.add(order)
        groups[region] = groups.get(region, Decimal(0)) + amount
    total = sum((amount for _, _, amount in clean), Decimal(0))
    if abs(total) > Decimal("1000000000000") or any(abs(amount) > Decimal("1000000000000") for amount in groups.values()):
        raise SummaryInputError("Aggregate amount outside the example's precision/range")
    book = Workbook()
    try:
        raw_sheet = book.active
        raw_sheet.title = "Input"
        for row in rows:
            raw_sheet.append(row)
        data = book.create_sheet("Data")
        data.append(["Order", "Region", "Amount", "Share"])
        for order, region, amount in clean:
            data.append([order, region, float(amount), float(amount / total) if total else 0])
        data.append(["Total", None, float(total), 1 if total else 0])
        regions = book.create_sheet("Regions")
        regions.append(["Region", "Amount", "Share"])
        for region, amount in sorted(groups.items()):
            regions.append([region, float(amount), float(amount / total) if total else 0])
        regions.append(["Total", float(total), 1 if total else 0])
        for sheet in book:
            for row in sheet.iter_rows():
                for cell in row:
                    # CSV is input data, never a formula or workbook error.
                    if isinstance(cell.value, str):
                        cell.data_type = "s"
                    cell.font = Font(name=font, size=11)
            sheet.freeze_panes = "A2"
        for sheet, money_column, percent_column in ((data, 3, 4), (regions, 2, 3)):
            # Determine the saved total row AFTER append. verify.py must locate
            # its unique label independently, rather than trust this variable.
            total_row = sheet.max_row
            for row in sheet.iter_rows(min_row=2, max_row=total_row):
                row[money_column - 1].number_format = "0.00"
                row[percent_column - 1].number_format = "0.0%"
            for cell in sheet[total_row]:
                cell.font = Font(name=font, size=11, bold=True)
                cell.fill = PatternFill("solid", fgColor="FFDEEAF6")
            sheet.column_dimensions["A"].width = 20
            sheet.column_dimensions["B"].width = 18
        with destination.open("xb") as output:
            book.save(output)
    finally:
        book.close()
    return {"status": "created", "file": str(destination), "data_rows": len(clean), "groups": len(groups)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--font", default="Arial")
    args = parser.parse_args()
    try:
        result = create(args.source, args.destination, args.font)
    except Exception as error:
        # Do not echo CSV contents in failure output.
        failure = {"status": "error", "error_type": type(error).__name__}
        if isinstance(error, SummaryInputError):
            failure["reason"] = str(error)
        print(json.dumps(failure))
        return 1
    print(json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
