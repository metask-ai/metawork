# Verify the saved workbook

Use the current XLSX Skill's private run entry for `scripts/verify.py`. The
checker reads the final candidate; it never edits it or installs libraries.
Use new paths for generated/edited candidates, check specifications and every
report. A verification-only task may inspect its authorized existing workbook
as a read-only candidate; no new workbook or change to the original is needed.

```sh
# Windows: use the run.cmd entry in place of /bin/sh .../run.sh.
/bin/sh "${CLAUDE_SKILL_DIR}/environment/run.sh" python "${CLAUDE_SKILL_DIR}/scripts/verify.py" result.xlsx verification-1.json --checks checks.json
```

Use the documented forms below to author the specification. For a matching
cleaning/summary task, read `examples/summary.py` and
`examples/orders-checks.json` together as the runnable starting point. Adapt the
checks to the actual task and derive expectations from its input. You do not
need to inspect the checker implementation to discover these fields; investigate
implementation details when a concrete error is not explained by this reference.

Read the report, paging through it when the reader truncates its output. Do not
infer unseen check or requirement results from a partial view. Reports use
multiline JSON so the normal text reader can inspect them directly. Read
`status`, `execution_completed`,
`required_checks_completed`, `conforms`, the per-check results and the requirement
mapping. Exit zero alone does not establish that the task was checked. A call
without `--checks` only establishes the reported basic checks (`basic_passed`),
with `conforms: null`. It does not verify the user's contents or formatting.

This also applies when a necessary operation cannot be performed. Keep it in
the specification, run the checker against the inspected workbook, and use the
structured incomplete report to support the explanation. For example:

```json
{
  "version": 1,
  "requirements": [
    {"id": "engine", "source": "User requires actual calculation-engine execution", "checks": ["engine"]}
  ],
  "checks": [
    {"id": "engine", "op": "unsupported", "reason": "No supported calculation engine is available"}
  ]
}
```

That necessary check remains incomplete (`required_checks_completed: false`,
`conforms: null`); it cannot become passed by explaining the limitation in
prose. If the candidate itself cannot be read or checking cannot execute,
report that execution failure without inventing a completed report.

Before generating the document, map every necessary user requirement to a check
or an explicit unsupported item. Keep this mapping when correcting the document
or the specification. `requirements[].source` states whether the expectation came
from the user's request, a preserved original or an independent computation over
the raw input. A mapping is a work record; it cannot prove that natural-language
requirements were fully understood. Review the mapping against the actual task.

Use independent expected values for cleaned counts, totals and groups. Checking
only A1 does not cover data rows or a total appended elsewhere. Find each total
by a unique label within its declared table, and check its expected coordinate.
Check every required font range and each percentage range, including totals.
Re-read the candidate to identify totals; do not copy an authoring script's
`total_row` into the checker and assume the row is correct.

The following is a small specification example for a sheet with one total in
A6 and an amount of 650 in C6. Adapt the expected coordinate, amount and ranges
from the task; this example does not establish all business requirements.

```json
{
  "version": 1,
  "requirements": [
    {
      "id": "total",
      "source": "User request and independent sum of raw input",
      "checks": ["total-position", "amount"]
    },
    {
      "id": "font",
      "source": "User requested Arial throughout this table",
      "checks": ["font"]
    },
    {
      "id": "percent",
      "source": "User requested one decimal percentage including the total",
      "checks": ["percent"]
    }
  ],
  "checks": [
    {
      "id": "total-position",
      "op": "label",
      "target": { "sheet": "Data", "range": "A2:A6" },
      "expected": { "value": "Total", "cell": "A6" }
    },
    {
      "id": "amount",
      "op": "values",
      "target": {
        "sheet": "Data",
        "label": { "range": "A2:A6", "value": "Total" },
        "offset": [0, 2]
      },
      "expected": [[{ "type": "number", "value": 650, "tolerance": 0 }]]
    },
    {
      "id": "font",
      "op": "font",
      "target": { "sheet": "Data", "range": "A1:D6" },
      "expected": { "name": "Arial", "size": 11 }
    },
    {
      "id": "percent",
      "op": "number_format",
      "target": { "sheet": "Data", "range": "D2:D6" },
      "expected": "0.0%"
    }
  ]
}
```

`target.range` is an explicit A1 cell or rectangle. A label target contains
`sheet` and `label: {range, value}`; `offset: [rows, columns]` selects relative to
the unique match, and `size: [rows, columns]` defaults to `[1, 1]`. Zero or
multiple matches fail. A nonempty style assertion over an empty area fails;
use an explicit `count` assertion with expected zero when the task permits an
empty dataset. Valid coordinates outside the stored area still get checked. A
requested font range includes blank cells; explicitly style those cells when
authoring.

Supported operations are finite. These are the exact check-object forms for
entries in `checks`; choose the operations needed by the task, adapt selectors
and expectations, and map every selected check ID in `requirements` as above.
These illustrative objects are not a complete acceptance specification for a
user workbook.

```json
[
  {"id":"sheets","op":"sheets","expected":["Data","Reference"]},
  {"id":"values","op":"values","target":{"sheet":"Data","range":"A1:D1"},"expected":[[{"type":"string","value":"Example"},{"type":"number","value":42.75,"tolerance":0},{"type":"blank"},{"type":"boolean","value":true}]]},
  {"id":"formula","op":"values","target":{"sheet":"Reference","range":"B2"},"expected":[[{"type":"formula","value":"=1+2"}]]},
  {"id":"total-position","op":"label","target":{"sheet":"Data","range":"A2:A6"},"expected":{"value":"Total","cell":"A6"}},
  {"id":"orders","op":"count","target":{"sheet":"Data","range":"A2:A5"},"expected":4},
  {"id":"font","op":"font","target":{"sheet":"Data","range":"A1:D6"},"expected":{"name":"Arial","size":11}},
  {"id":"fill","op":"fill","target":{"sheet":"Data","range":"A6"},"expected":{"pattern":"solid","color":"FFDEEAF6"}},
  {"id":"percentage","op":"number_format","target":{"sheet":"Data","range":"D2:D6"},"expected":"0.0%"},
  {"id":"preserved","op":"unchanged","target":{"sheet":"Reference","range":"A1:H20"},"original":"original.xlsx","properties":["value","font","fill","number_format"]},
  {"id":"engine","op":"unsupported","reason":"No supported calculation engine is available"}
]
```

`count` counts nonempty cells, including stored formula strings. To check a row
count, select the required identifier column rather than the entire table.
`font.expected` is a nonempty subset of `name`, `size`, `bold`, `italic`, `color`;
`fill.expected` is a nonempty subset of `pattern`, `color` for directly represented
solid/empty fills. `unchanged` uses top-level `original` and `properties`, without
`expected`; it compares the same declared target in the distinct original.
An empty fill is asserted as `"expected":{"pattern":null}`; use it to check
that an incorrectly highlighted detail row has actually been cleared.
`sheets` and `unsupported` have no target. Do not add fields from another operation.

Value types are `blank` (no value), `boolean`, `string`, `number`, `formula`,
`date`, `datetime` and `error`. A blank contains only `type`; the other value
types include `value`. Dates, datetimes and error literals use string values.
A number requires a nonnegative explicit
`tolerance`; booleans and blanks do not equal numeric zero. Formulas are exact
strings starting with `=`; dates use ISO text. Formula text checks do not
calculate formulas or establish current cache values. Colors use explicit
eight-digit ARGB; theme/indexed/tinted colors and overlapping conditional or
merged-cell style scopes can be unsupported. Stored fonts do not prove installed
fonts or viewer appearance. The report always identifies rendering, viewer
compatibility, recalculation and full XSD validation as unperformed.

`unchanged` compares the complete saved font/fill properties, including color
references, and requires the workbook theme and indexed palette to stay identical
when comparing those properties. This supports preserving ordinary default theme
styles without resolving their visual colors. Conditional/merged scope limits
still apply; this comparison does not establish appearance in a viewer.

The specification must contain `version`, `checks` and `requirements`; every
requirement has unique `id`, `source`, `checks` and optionally `required` (default
true). Preserve unmapped necessary requirements. Do not invent requirements just
to make the mapping nonempty, delete failed checks, change expected values to
match wrong output, or relax tolerances to obtain a pass. Unknown fields,
operations, out-of-format selectors and excessive specifications are rejected.
Workbook, XML, traversal, time, reference and report budgets are enforced; narrow
an unnecessarily broad query only when the necessary task coverage is preserved.

Handle the actual result:

| Exit | Report                                     | Next action                                                                                                                                                   |
| ---- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | `passed` or `basic_passed`                 | Check the actual scope and mapping; basic-only is insufficient for business or style claims                                                                   |
| 1    | `failed`                                   | Compare with the task. Correct a confirmed candidate defect within the authorized scope; correct a miswritten specification without weakening the requirement |
| 2    | `spec_error`                               | Correct the specification; this is not evidence that the workbook needs editing                                                                               |
| 3    | `incomplete`                               | State necessary unsupported/unexecuted checks; do not claim successful completion                                                                             |
| 4    | `execution_error` or stdout `report_error` | Handle the actual environment, permission, I/O or budget failure; do not automatically modify the workbook or change dependency sources                       |

Do not repeat unchanged inputs hoping for a different result. After any candidate
edit, use a fresh report and check the new saved bytes. Reports are ordinary
Workspace files and can contain document values. Do not send them to application
logs, include them in final answers or deliver them unless the user requested it.
Do not consume partial/interrupted JSON or a stale report as a successful check.

Before delivery, ensure the candidate still has the report's size and SHA-256.
Call the existing `DeliverFile` with the candidate's Workspace-relative path.
Compare the actual committed receipt's byte size and SHA-256 to
`report.candidate.bytes` and `report.candidate.sha256`. A report is not Host
authority; DeliverFile still proves its own file identity. If the receipt differs,
keep the actual delivery record, state that the check did not cover the delivered
bytes and check those bytes as needed. Do not automatically delete an output or
repeat DeliverFile. State delivery, checked scope and outstanding requirements
separately, based on actual results.

# Runnable cleaning and summary example

`examples/summary.py source.csv summary.xlsx` runs via the same private Python
entry and creates a new file. Its input header and cleaning/zero-total rules are
documented in the script; use it only when those rules match the task. It styles
the actual appended total rows and percentage cells. It does not create its own
passing check specification: derive independent expectations from the raw input
and use `verify.py` on its saved result. For example, four accepted orders with
amounts 100, 200, 150 and 200 total 650; North 300 and South 350 require separate
group checks, rather than a check of the overall sum alone.

For a complete runnable sample, use `examples/orders.csv` with the script and
verify the result with `examples/orders-checks.json`. That specification includes
the data and region amounts/shares, both total positions, counts, fonts and
percentage ranges. Its expectations belong to this bundled sample only; do not
reuse them as the truth for a different user input. The example authoring script
does not import or generate its check specification.
