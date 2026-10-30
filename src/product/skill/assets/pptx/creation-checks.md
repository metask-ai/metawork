# Finish a newly authored presentation

The fixed generator and the strict OOXML checker form one creation workflow. A generator write alone is not a checked presentation. Keep the generated intermediate and create a separate checked candidate:

```text
run.cmd node create.cjs
run.cmd python "${CLAUDE_SKILL_DIR}/scripts/finalize.py" generated.pptx checked.pptx
```

Use the absolute run entry from SKILL.md; on macOS substitute `/bin/sh "${CLAUDE_SKILL_DIR}/environment/run.sh"`. Use new Workspace paths and quote each argument. The Node script must write `generated.pptx`. The finishing step requires private Python as well as Node; follow the existing preparation and consent workflow if either is missing. Do not install another generator or run through system interpreters.

For an ordinary, unstacked line chart, explicitly declare its intended semantics:

```text
run.cmd python "${CLAUDE_SKILL_DIR}/scripts/finalize.py" generated.pptx checked.pptx --line-grouping standard
```

Do not use that flag for stacked lines or infer grouping from a missing XML field. Clarify an ambiguous task before selecting chart semantics. A missing grouping without the declaration is rejected.

## Scope and failures

Use this operation only immediately after authoring a new presentation through this Skill's fixed PptxGenJS. Do not run it on an existing user presentation, an imported template, or an already edited original; use [editing.md](editing.md) for those files.

The operation checks bounded archive/XML input and handles a finite set of generated structures: the notes-master list order, per-point chart styling before series labels, one unused extra reference in a single two-dimensional category/value axis pair, and standard line-chart structure. Styled points must identify existing entries in consistent single-level category/value caches. It preserves the other package contents, including notes, chart data, embedded workbooks, relationships, media and slide text. Combined charts, unrecognized axis/cache patterns and nonstandard line grouping are outside this processing scope. It does not guess how to repair them. Its bounded diagnostic summary counts known operations and changed parts.

Every candidate must pass the existing strict PPTX validator in full. The operation does not subtract original errors or enable auto-repair. On rejection or execution error there is no successful candidate; inspect the fixed reason, adjust the authoring choices if the task permits, and run again with a new output path. Never bypass validation, remove a requested feature silently, patch the installed library, or describe a failed structure check as an unsupported visual check.

## Inspect and deliver the exact candidate

Exit 0 and `status: structure_passed` mean structural checks passed. They do not prove the user's text, totals, chart labels or presentation design correct. Read the final `checked.pptx` through the Skill's structured reader and checked XML. Compare slide order, specified text, notes, categories, series values, styles and relationships with the task's independently determined requirements. Targeted edits must use a new working copy and run the strict validator again.

Record the final candidate's size and SHA-256 from the successful result. After any subsequent edit, revalidate and recompute both for the actual candidate. Deliver that file through DeliverFile and compare its actual receipt with the checked bytes. If they differ, preserve the actual delivery fact and state that the earlier check does not cover the delivered bytes; do not claim a checked delivery or automatically delete/re-deliver it.

The creation structures have finite MetaskOffice feature compatibility evidence. This is not Microsoft PowerPoint testing, a visual inspection of the current file, or a guarantee about untested presentation features. The current tools provide no rendering or viewer operation. Say precisely which structure/content checks ran and which visual or PowerPoint checks did not run.
