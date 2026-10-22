---
name: pptx
description: Plan and review presentations, slide narratives, speaker notes and .pptx decks. Includes basic guidance; presentation execution requires the optional Office environment.
---

# PowerPoint presentations

This basic Skill provides working methods, not a Python, Node or Office installation. Skill discovery alone does not mean presentation execution is available. For PPTX extraction, creation, editing, validation or slide rendering, ask the user to prepare the optional MetaWork Office component. Then explicitly refresh the idle Task's Skills and invoke its complete PPTX Skill. Do not guess executable paths, install packages, use a system Office installation as a fallback, or claim an unperformed operation succeeded.

Before execution is available, you can develop the narrative, draft slide text and suggest a visual outline in the conversation. Confirm the audience, objective, presentation length, aspect ratio and source material. Clearly distinguish an outline from a delivered slide deck.

When working with a prepared component:

- Keep attachment originals unchanged and edit a workspace copy.
- Inspect actual slide order, hidden slides, notes, masters, layouts and relationships. ZIP member ordering is not presentation ordering.
- Give each slide one clear purpose. Establish a consistent grid, typography and color hierarchy; use concise labels and cite the source of factual claims and data.
- Preserve relationships, image aspect ratios and editable structure as the task requires. Avoid accidental loss of notes or hidden slides.
- Validate the package and render every slide, including hidden slides when checking completeness. Inspect text overflow, clipping, alignment, contrast, charts and Chinese glyphs; do not infer visual correctness from XML validation alone.
- Deliver the actual checked presentation and explain changes and limitations. Markdown slide text or exported images alone are not an editable PPTX.
- After the final file is checked, follow the complete Skill to call the Host tool `DeliverFile` with its Workspace-relative path. Observe the actual result; a Markdown path is not a registered Output, and Host byte verification is not a document quality check. Without the prepared component, continue to provide guidance rather than claiming a file was produced or delivered.

Legacy .ppt, macros, encrypted presentations and perfect fidelity of complex layouts are outside this workflow's initial scope.
