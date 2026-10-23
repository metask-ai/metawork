---
name: pptx
description: Create, read, edit, combine, split, and refine PowerPoint presentations. Use for .pptx files, slides, decks, presentations, templates, layouts, speaker notes, comments, and extracting presentation content.
---

# PPTX Skill

## Execution environment

This is a complete built-in Skill. Its private environment may not be prepared yet. Only Windows x64 automatic preparation is supported.

Use the absolute resource entries `${CLAUDE_SKILL_DIR}/environment/prepare.cmd` and `${CLAUDE_SKILL_DIR}/environment/run.cmd` through the existing Shell, preserving Windows argument quoting. Never infer an executable from the parent of this resource directory.

First use `prepare.cmd python` or `prepare.cmd node` only to reuse an existing environment **after consent has already been obtained**, or use `run.cmd python ...` / `run.cmd node ...` to execute: run never downloads and reports a missing environment. Before first preparation, tell the user its purpose and the fixed download sizes in [environment inputs](environment/environment.json), plus the required library download, and ask for agreement. Then call the fixed prepare entry for the needed language. No arbitrary URL, package list or version arguments are supported. DOCX/PPTX creation and Python validation may need both environments. If preparation fails or is refused, explain the limitation and continue what is possible. Do not install globally or change user configuration. Consent is a conversation instruction; full_access has no additional product installation gate.

The prepared directories are shared under the user's LocalAppData/MetaWork/OfficeDependencies. Do not update, rename or delete completed environments or ask the user to delete them. Private dependencies are not an execution sandbox. Write task scripts, working copies and outputs in the Task workspace. Use `from office_archive import checked_copy` and load only the private checked path inside its context when passing an existing Office file to a library. Never overwrite the attachment original.

This edition cannot render documents, export PDF, accept revisions or recalculate formulas. Do not invent visual QA or calculation results. XLSX may request recalculation on open, but this does not calculate or populate caches now.

## Read, check and deliver

For bounded structured text: `run.cmd python "${CLAUDE_SKILL_DIR}/environment/read.py" input.docx new-content.json` (also XLSX/PPTX). For XML work, run the scripts under `scripts/office/` with `run.cmd python`, using new output directories. Reopen and inspect changed content and validate supported structures before delivery. Report unsupported features and checks not performed.

Call the Host tool `DeliverFile` with the actual Task Workspace-relative output path, e.g. `{"path":"results/report.docx"}`. This is a tool call, not a Shell command or text to print. Deliver only finished files requested by the user, not temporary XML, scripts or check output.

## Workflows

- Create with the fixed PptxGenJS library: read [pptxgenjs.md](pptxgenjs.md), save a script and execute `run.cmd node create.cjs`.
- Read or edit an existing file: read [editing.md](editing.md), inspect structured text and checked XML, then make focused changes on a working copy.
- Validate and reopen the finished file, checking slide order, text, notes, relationships and changed structures. Visual inspection and rendering are unavailable; say so explicitly.

## Design Ideas

**Don't create boring slides.** Plain bullets on a white background won't impress anyone. Consider ideas from this list for each slide.

### Before Starting

- **Pick a bold, content-informed color palette**: The palette should feel designed for THIS topic. If swapping your colors into a completely different presentation would still "work," you haven't made specific enough choices.
- **Dominance over equality**: One color should dominate (60-70% visual weight), with 1-2 supporting tones and one sharp accent. Never give all colors equal weight.
- **Dark/light contrast**: Dark backgrounds for title + conclusion slides, light for content ("sandwich" structure). Or commit to dark throughout for a premium feel.
- **Commit to a visual motif**: Pick ONE distinctive element and repeat it — rounded image frames, icons in colored circles, thick single-side borders. Carry it across every slide.

### Color Palettes

Choose colors that match your topic — don't default to generic blue. Use these palettes as inspiration:

| Theme | Primary | Secondary | Accent |
|-------|---------|-----------|--------|
| **Midnight Executive** | `1E2761` (navy) | `CADCFC` (ice blue) | `FFFFFF` (white) |
| **Forest & Moss** | `2C5F2D` (forest) | `97BC62` (moss) | `F5F5F5` (cream) |
| **Coral Energy** | `F96167` (coral) | `F9E795` (gold) | `2F3C7E` (navy) |
| **Warm Terracotta** | `B85042` (terracotta) | `E7E8D1` (sand) | `A7BEAE` (sage) |
| **Ocean Gradient** | `065A82` (deep blue) | `1C7293` (teal) | `21295C` (midnight) |
| **Charcoal Minimal** | `36454F` (charcoal) | `F2F2F2` (off-white) | `212121` (black) |
| **Teal Trust** | `028090` (teal) | `00A896` (seafoam) | `02C39A` (mint) |
| **Berry & Cream** | `6D2E46` (berry) | `A26769` (dusty rose) | `ECE2D0` (cream) |
| **Sage Calm** | `84B59F` (sage) | `69A297` (eucalyptus) | `50808E` (slate) |
| **Cherry Bold** | `990011` (cherry) | `FCF6F5` (off-white) | `2F3C7E` (navy) |

### For Each Slide

**Every slide needs a visual element** — image, chart, icon, or shape. Text-only slides are forgettable.

**Layout options:**
- Two-column (text left, illustration on right)
- Icon + text rows (icon in colored circle, bold header, description below)
- 2x2 or 2x3 grid (image on one side, grid of content blocks on other)
- Half-bleed image (full left or right side) with content overlay

**Data display:**
- Large stat callouts (big numbers 60-72pt with small labels below)
- Comparison columns (before/after, pros/cons, side-by-side options)
- Timeline or process flow (numbered steps, arrows)

**Visual polish:**
- Icons in small colored circles next to section headers
- Italic accent text for key stats or taglines

### Typography

**Choose an interesting font pairing** — don't default to Arial. Pick a header font with personality and pair it with a clean body font.

| Header Font | Body Font |
|-------------|-----------|
| Georgia | Calibri |
| Arial Black | Arial |
| Calibri | Calibri Light |
| Cambria | Calibri |
| Trebuchet MS | Calibri |
| Impact | Arial |
| Palatino | Garamond |
| Consolas | Calibri |

| Element | Size |
|---------|------|
| Slide title | 36-44pt bold |
| Section header | 20-24pt bold |
| Body text | 14-16pt |
| Captions | 10-12pt muted |

### Spacing

- 0.5" minimum margins
- 0.3-0.5" between content blocks
- Leave breathing room—don't fill every inch

### Avoid (Common Mistakes)

- **Don't repeat the same layout** — vary columns, cards, and callouts across slides
- **Don't center body text** — left-align paragraphs and lists; center only titles
- **Don't skimp on size contrast** — titles need 36pt+ to stand out from 14-16pt body
- **Don't default to blue** — pick colors that reflect the specific topic
- **Don't mix spacing randomly** — choose 0.3" or 0.5" gaps and use consistently
- **Don't style one slide and leave the rest plain** — commit fully or keep it simple throughout
- **Don't create text-only slides** — add images, icons, charts, or visual elements; avoid plain title + bullets
- **Don't forget text box padding** — when aligning lines or shapes with text edges, set `margin: 0` on the text box or offset the shape to account for padding
- **Don't use low-contrast elements** — icons AND text need strong contrast against the background; avoid light text on light backgrounds or dark text on dark backgrounds
- **NEVER use accent lines under titles** — these are a hallmark of AI-generated slides; use whitespace or background color instead

---

