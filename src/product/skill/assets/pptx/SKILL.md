---
name: pptx
description: Create, read, edit, combine, split, and refine PowerPoint presentations. Use for .pptx files, slides, decks, presentations, templates, layouts, speaker notes, comments, and extracting presentation content.
---

# PPTX Skill

## Execution environment

Skill resource directory: `${CLAUDE_SKILL_DIR}`

This Skill is provided by the optional Windows Office component. Use its absolute entry `${CLAUDE_SKILL_DIR}/../../bin/office.exe`; do not look up Python, Node or an Office installation through PATH. If the component is unavailable, report that Office support must be enabled through the product. Do not install dependencies during document processing.

Keep attachment originals unchanged. Write scripts, fresh unpacked data directories and outputs in the Task workspace. Resolve helper paths from this Skill resource directory. Use the component's `python` command for Python scripts and `node` command for JavaScript scripts; these commands supply the component's libraries only for that invocation.

The `text` command writes bounded structured JSON, including Word revision runs and tables, presentation slide order and notes, or worksheet cells with formulas and cached values. It does not perform OCR. Use the bounded unpack helper when you need selected raw XML parts. Before passing an existing OOXML file to a Python library, use `from office_archive import checked_copy` and pass the path yielded by that context; do not check one path and then load the original.

Conversions accept a new output path and never overwrite it. A nonzero exit, missing result, formula error or incomplete preview is a failure. Inspect results before reporting success.

Legacy binary Office formats, document macros and encrypted files are outside this Skill's supported workflow.

## Explicit file delivery

Validate and reopen the PPTX, verify slide order, notes and requested changes, and inspect the rendered slides for overflow and clipping. State any checks you could not perform. Host file verification does not establish document quality.

After checking the final file, call the Host tool `DeliverFile` with arguments `{"path":"results/presentation.pptx"}`, using the actual Task Workspace-relative path with forward slashes. This is a tool call, not a Shell command or text to print. Submit only the finished files requested by the user; keep unpacked XML, scripts, temporary files and preview images as working material unless explicitly requested.

Observe the actual tool result. `verified_for_delivery` confirms the Host checked the bytes and issued a receipt; the Task Outputs record determines registration. If the tool is unavailable or fails, report that delivery was not confirmed. A Markdown path or Shell output cannot register an Output. Describe the changes and any remaining limitations after the real result.

Do not change a file after submitting it; finish further edits and checks before submitting the new result. A read-only analysis can end with a conversational answer and does not require a new file.

## Quick Reference

| Task | Guide |
|------|-------|
| Read/analyze content | Component `text` command |
| Edit or create from template | Read [editing.md](editing.md) |
| Create from scratch | Read [pptxgenjs.md](pptxgenjs.md) |

---

## Reading Content

```bash
# Text extraction
"${CLAUDE_SKILL_DIR}/../../bin/office.exe" text presentation.pptx content.json

# Visual overview
"${CLAUDE_SKILL_DIR}/../../bin/office.exe" render presentation.pptx preview-pages/

# Raw XML
"${CLAUDE_SKILL_DIR}/../../bin/office.exe" python "${CLAUDE_SKILL_DIR}/scripts/office/unpack.py" presentation.pptx unpacked/
```

---

## Editing Workflow

**Read [editing.md](editing.md) for full details.**

1. Analyze template with component page images and structured text
2. Unpack → manipulate slides → edit content → clean → pack

---

## Creating from Scratch

**Read [pptxgenjs.md](pptxgenjs.md) for full details.**

Use when no template or reference presentation is available.

---

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

## QA (Required)

**Assume there are problems. Your job is to find them.**

Your first render is almost never correct. Approach QA as a bug hunt, not a confirmation step. If you found zero issues on first inspection, you weren't looking hard enough.

### Content QA

```bash
"${CLAUDE_SKILL_DIR}/../../bin/office.exe" text output.pptx content.json
```

Check for missing content, typos, wrong order.

**When using templates, check for leftover placeholder text:**

```bash
rg -i "xxxx|lorem|ipsum|this.*(page|slide).*layout" content.json
```

If grep returns results, fix them before declaring success.

### Visual QA

Inspect the rendered slide images with the available image-reading tool. Use an independent reviewer when one is available and authorized; visual verification must also work without delegation.

Convert slides to images (see [Converting to Images](#converting-to-images)), then use this prompt:

```
Visually inspect these slides. Assume there are issues — find them.

Look for:
- Overlapping elements (text through shapes, lines through words, stacked elements)
- Text overflow or cut off at edges/box boundaries
- Decorative lines positioned for single-line text but title wrapped to two lines
- Source citations or footers colliding with content above
- Elements too close (< 0.3" gaps) or cards/sections nearly touching
- Uneven gaps (large empty area in one place, cramped in another)
- Insufficient margin from slide edges (< 0.5")
- Columns or similar elements not aligned consistently
- Low-contrast text (e.g., light gray text on cream-colored background)
- Low-contrast icons (e.g., dark icons on dark backgrounds without a contrasting circle)
- Text boxes too narrow causing excessive wrapping
- Leftover placeholder content

For each slide, list issues or areas of concern, even if minor.

Read and analyze these images:
1. /path/to/slide-01.jpg (Expected: [brief description])
2. /path/to/slide-02.jpg (Expected: [brief description])

Report ALL issues found, including minor ones.
```

### Verification Loop

1. Generate slides → Convert to images → Inspect
2. **List issues found** (if none found, look again more critically)
3. Fix issues
4. **Re-verify affected slides** — one fix often creates another problem
5. Repeat until a full pass reveals no new issues

Report success only after content and visual checks pass. When a check finds an issue, fix it and re-verify the affected slides.

---

## Converting to Images

```bash
"${CLAUDE_SKILL_DIR}/../../bin/office.exe" render output.pptx preview-pages/
"${CLAUDE_SKILL_DIR}/../../bin/office.exe" pdf output.pptx exported.pdf
```

Read `preview-pages/pages.json` and inspect every listed page image. The component prepares the document once per operation and exports explicit page objects; it verifies the page count, image dimensions and byte budgets. Render again into a new directory after edits. A successful process exit alone is not visual QA.

## Authoring runtime

Use the component's packaged PptxGenJS: save the JavaScript as `create.cjs`, then run `"${CLAUDE_SKILL_DIR}/../../bin/office.exe" node create.cjs`. The component contains the Python libraries required by the XML helpers. Do not install global tools or change the Task-wide environment.
