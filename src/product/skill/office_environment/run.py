"""Call-local Python paths; no environment preparation or global mutation."""
import os
from pathlib import Path
import runpy
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from finish import check

root = Path(os.environ["METAWORK_OFFICE_ENV"])
check(root)
sys.argv = sys.argv[2:]
if not sys.argv:
    raise SystemExit("A Python script is required")
sys.path.insert(2, str(Path(sys.argv[0]).resolve().parent))
runpy.run_path(sys.argv[0], run_name="__main__")
