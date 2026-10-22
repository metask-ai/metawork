---
name: docx
description: Plan and review Word documents, reports, letters and templates; use for .docx content, formatting, comments and tracked changes. Includes basic guidance; document execution requires the optional Office environment.
---

# Word documents

This basic Skill provides working methods, not a Python, Node or Office installation. Skill discovery alone does not mean document execution is available. For DOCX creation, extraction, editing, accepting revisions, validation or page rendering, ask the user to prepare the optional MetaWork Office component. Then explicitly refresh the idle Task's Skills and invoke its complete DOCX Skill. Do not guess executable paths, install packages, use a system Office installation as a fallback, or claim an unperformed operation succeeded.

Before execution is available, you can help draft and review content in the conversation. Confirm the intended audience, document purpose, sections, page size and delivery format; distinguish a content draft from a delivered Word file.

When working with a prepared component:

- Keep attachment originals unchanged and edit a workspace copy.
- Inspect document structure, tables, headers, footers, comments and revisions before choosing an edit method. A DOCX is a ZIP package of related XML parts; changing visible text alone may omit other parts.
- Preserve styles, numbering, relationships and section properties. Keep revision acceptance separate from merely hiding revision marks.
- Validate the package and inspect every rendered page, including table breaks, Chinese text, images and page numbering. State any unsupported features or unverified layout.
- Deliver the actual checked output file and describe its changes. Do not present a Markdown draft or a renamed file as a generated DOCX.

Legacy .doc, macros, encrypted documents and perfect fidelity of complex layouts are outside this workflow's initial scope.
