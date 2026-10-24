"""Read checked OOXML into bounded structured text; no rendering or calculation."""
from pathlib import Path
import sys
from office_archive import checked_copy
from document_text import extract

if len(sys.argv) != 3:
    raise SystemExit("Usage: read.py input.docx|xlsx|pptx new-output.json")
output = Path(sys.argv[2])
if output.exists():
    raise SystemExit("Output already exists")
with checked_copy(sys.argv[1]) as checked:
    extract(Path(checked), output)
