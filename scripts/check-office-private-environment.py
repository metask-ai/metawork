"""Opt-in Windows qualification: real downloads into an isolated test profile."""
import concurrent.futures
import atexit
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import urllib.request

REPO = Path(__file__).resolve().parents[1]
if sys.platform != "win32" or sys.argv[1:] not in (["--download"], ["--download", "--network-config-probe"]):
    raise SystemExit("Usage on Windows: python scripts/check-office-private-environment.py --download [--network-config-probe]")
scratch = Path(tempfile.mkdtemp(prefix="office-private qualification ", dir=REPO / ".zig-cache"))
resources = scratch / "resources"
resources.mkdir()
subprocess.run(["tar.exe", "-xf", str(REPO / "src/app/office-skills.tar.gz"), "-C", str(resources)], check=True)
entry = resources / "docx/environment"
profile = scratch / "profile"
env = dict(os.environ, LOCALAPPDATA=str(profile), NODE_OPTIONS="", NODE_PATH="")
network_requests = []
if "--network-config-probe" in sys.argv:
    class Mirror(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_GET(self):
            try:
                host = "https://pypi.org/" if self.path.startswith("/pypi/") else "https://registry.npmjs.org/"
                relative = self.path.split("/", 2)[2]
                with urllib.request.urlopen(host + relative, timeout=60) as upstream:
                    body = upstream.read()
                    self.send_response(upstream.status)
                    self.send_header("Content-Type", upstream.headers.get("Content-Type", "application/octet-stream"))
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                network_requests.append(self.path)
            except Exception:
                self.send_error(502, "qualification mirror failed")

    class MirrorServer(ThreadingHTTPServer):
        # npm opens many parallel downloads; the Windows default backlog of
        # five refuses bursts even though the fixture is serving correctly.
        request_queue_size = 128

    server = MirrorServer(("127.0.0.1", 0), Mirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    atexit.register(server.server_close)
    atexit.register(server.shutdown)
    # Read existing configuration through package-manager mechanisms. CLI must
    # still fix the destination even when configuration requests global installs.
    pip_config = scratch / "pip.ini"
    pip_config.write_text("[global]\nindex-url = http://127.0.0.1:" + str(server.server_port) + "/pypi/simple\ntrusted-host = 127.0.0.1\n", encoding="utf-8")
    npm_config = scratch / "npmrc"
    npm_config.write_text("registry=http://127.0.0.1:" + str(server.server_port) + "/npm/\nglobal=true\nprefix=" + str(scratch / "must-not-install") + "\n", encoding="utf-8")
    env.update(PIP_CONFIG_FILE=str(pip_config), NPM_CONFIG_USERCONFIG=str(npm_config))


def command(name, *args, environment=env):
    quoted = " ".join('"' + str(value) + '"' for value in [entry / name, *args])
    result = subprocess.run('cmd.exe /d /s /c "' + quoted + '"', env=environment,
                            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


# Duplicate fresh preparations race on publication, not writes in one directory.
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    node_results = list(pool.map(lambda _: command("prepare.cmd", "node"), range(2)))
command("prepare.cmd", "python")
home = profile / "MetaWork/OfficeDependencies"
assert len(list(home.glob("node-*"))) == 1
assert len(list(home.glob("python-*"))) == 1
assert not list(home.glob(".*.tmp"))
if "--network-config-probe" in sys.argv:
    assert any(p.startswith("/pypi/simple/openpyxl/") for p in network_requests), network_requests
    assert any(p.startswith("/npm/docx/-/") for p in network_requests), network_requests
    assert any(p.startswith("/npm/pptxgenjs/-/") for p in network_requests), network_requests
    assert not (scratch / "must-not-install").exists(), "npm configuration escaped the fixed private destination"


def inventory():
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in home.rglob("*") if p.is_file()}


before = inventory()
offline = dict(env, HTTPS_PROXY="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1", ALL_PROXY="http://127.0.0.1:1")
command("prepare.cmd", "python", environment=offline)
command("prepare.cmd", "node", environment=offline)
work = scratch / "work"
work.mkdir()
(work / "create.cjs").write_text('''const fs=require("node:fs"),path=require("node:path");
const {Document,Packer,Paragraph}=require("docx");const Slides=require("pptxgenjs");
(async()=>{const root=process.argv[2];
fs.writeFileSync(path.join(root,"created.docx"),await Packer.toBuffer(new Document({sections:[{children:[new Paragraph("Office 中文 test")]}]})));
const slides=new Slides();slides.addSlide().addText("Slides 中文 test",{x:1,y:1,w:8,h:2});await slides.writeFile({fileName:path.join(root,"created.pptx")});})();
''', encoding="utf-8")
(work / "create.py").write_text('''from pathlib import Path
import sys
from openpyxl import Workbook,load_workbook
from openpyxl.workbook.properties import CalcProperties
from office_archive import checked_copy
root=Path(sys.argv[1]);book=Workbook();sheet=book.active;sheet["A1"]="中文";sheet["A2"]=5;sheet["B2"]=7;sheet["C2"]="=SUM(A2:B2)";book.calculation=CalcProperties(fullCalcOnLoad=True);book.save(root/"created.xlsx");book.close()
with checked_copy(root/"created.xlsx") as checked:
 book=load_workbook(checked);book.active["B2"]=9;book.save(root/"edited.xlsx");book.close()
''', encoding="utf-8")
command("run.cmd", "node", work / "create.cjs", work)
command("run.cmd", "python", work / "create.py", work)
for suffix, source in [("docx", "created.docx"), ("pptx", "created.pptx"), ("xlsx", "edited.xlsx")]:
    command("run.cmd", "python", entry / "read.py", work / source, work / (suffix + ".json"))
    result = json.loads((work / (suffix + ".json")).read_text(encoding="utf-8"))
    assert result["format"] == suffix
    assert "中文" in json.dumps(result, ensure_ascii=False)
assert before == inventory(), "Document processing changed the completed environment"
print(json.dumps({"scratch": str(scratch), "concurrent_node_publish": True, "offline_reuse": True,
                  "docx_pptx_creation": True, "xlsx_edit": True, "three_format_read": True,
                  "environment_unchanged": True, "files": len(before), "network_config_requests": len(network_requests)}, ensure_ascii=True))
