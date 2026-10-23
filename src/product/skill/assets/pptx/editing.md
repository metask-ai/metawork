# Editing presentations

Use the private Python entry from SKILL.md. Extract bounded structured text with environment/read.py; then unpack a working copy using scripts/office/unpack.py. Inspect slide relationships, layouts, text and notes. Do not claim to have viewed rendered slides.

Make focused XML edits. For slide duplication use scripts/add_slide.py and update the presentation relationships and ordered slide list consistently. Remove abandoned relationships and media only when their consumers have been checked.

Run scripts/clean.py on the working directory when needed. Pack to a new output with scripts/office/pack.py using the original as the structural comparison input. Run scripts/office/validate.py and reopen the output. Preserve originals and report limitations; deliver only the final requested file through DeliverFile.
