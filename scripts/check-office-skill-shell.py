"""Windows opt-in: canonical Core materializes Skills and executes real Bash calls.

Requires a profile prepared by check-office-private-environment.py and the
build-office-skill-shell executable. Uses only a loopback provider fixture.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--profile", type=Path, required=True)
args = parser.parse_args()
profile = args.profile.resolve(strict=True)
scratch = Path(tempfile.mkdtemp(prefix="office-core shell ", dir=REPO / ".zig-cache"))
skills = scratch / "skills"
skills.mkdir()
subprocess.run(["tar.exe", "-xf", str(REPO / "src/app/office-skills.tar.gz"), "-C", str(skills)], check=True)
probe = REPO / ".zig-cache/office-core-qualification/bin/office-skill-shell.exe"


def texts(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from texts(item)
    elif isinstance(value, list):
        for item in value:
            yield from texts(item)
    elif isinstance(value, str):
        yield value


def sse(tool_input=None):
    events = [{"type": "message_start", "message": {"id": "office-fixture", "role": "assistant",
              "model": "fixture", "usage": {"input_tokens": 1, "output_tokens": 1}}}]
    if tool_input:
        block = {"type": "tool_use", "id": "office-bash", "name": "Bash", "input": {}}
        delta = {"type": "input_json_delta", "partial_json": json.dumps(tool_input)}
    else:
        block = {"type": "text", "text": ""}
        delta = {"type": "text_delta", "text": "Office materialized resource passed"}
    events.extend([
        {"type": "content_block_start", "index": 0, "content_block": block},
        {"type": "content_block_delta", "index": 0, "delta": delta},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": "tool_use" if tool_input else "end_turn"},
         "usage": {"output_tokens": 1}}, {"type": "message_stop"}])
    return "".join("event: " + e["type"] + "\ndata: " + json.dumps(e) + "\n\n" for e in events).encode()


for kind in ("docx", "xlsx", "pptx"):
    work = scratch / kind
    work.mkdir()
    output = work / ("created." + kind)
    edited = work / ("edited." + kind)
    edit_script = work / "edit.py"
    edit_script.write_text('''import sys,zipfile
from pathlib import Path
from office_archive import checked_copy
from lxml import etree
source,destination=map(Path,sys.argv[1:])
with checked_copy(source) as checked,zipfile.ZipFile(checked) as original,zipfile.ZipFile(destination,"x",compression=zipfile.ZIP_DEFLATED) as changed:
 for member in original.infolist():
  content=original.read(member)
  if member.filename.endswith(".xml"):
   root=etree.fromstring(content)
   for element in root.iter():
    if element.text and "Office 中文" in element.text: element.text=element.text.replace("Office 中文","Office 中文 edited")
   content=etree.tostring(root,encoding="UTF-8",xml_declaration=True)
  changed.writestr(member,content)
''', encoding="utf-8")
    marker = "office-" + kind + "-materialized-ok"
    if kind == "xlsx":
        language = "python"
        script = work / "create.py"
        script.write_text('from openpyxl import Workbook\nimport sys\nw=Workbook();w.active["A1"]="Office 中文";w.active["B1"]="=1+2";w.save(sys.argv[1])\n', encoding="utf-8")
    else:
        language = "node"
        script = work / "create.cjs"
        code = ('const fs=require("node:fs"),{Document,Packer,Paragraph}=require("docx");'
                'Packer.toBuffer(new Document({sections:[{children:[new Paragraph("Office 中文")]}]})).then(b=>fs.writeFileSync(process.argv[2],b));') if kind == "docx" else (
                'const P=require("pptxgenjs");const p=new P();p.addSlide().addText("Office 中文",{x:1,y:1,w:8,h:2});p.writeFile({fileName:process.argv[2]});')
        script.write_text(code, encoding="utf-8")
    state = {"calls": 0, "error": None}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_POST(self):
            try:
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                (work / ("request-" + str(state["calls"]) + ".json")).write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
                state["calls"] += 1
                if state["calls"] == 1:
                    content = "\n".join(texts(payload))
                    candidates = re.findall(r"[A-Za-z]:[\\/][^`\"\r\n<>]+?[\\/]environment[\\/]run\.cmd", content)
                    existing = [Path(p) for p in candidates if Path(p).is_file()]
                    if not existing:
                        raise AssertionError("No expanded absolute run.cmd in materialized Skill; inspect request-0.json")
                    entry = existing[-1]
                    assert not entry.is_relative_to(skills), "Core used original source, not materialized resources"
                    state["entry"] = str(entry)
                    def quote(value):
                        return "'" + str(value).replace("'", "''") + "'"
                    ps = "$ErrorActionPreference='Stop'; & " + quote(entry) + " " + language + " " + quote(script) + " " + quote(output)
                    ps += "; if ($LASTEXITCODE -ne 0) { throw 'create failed' }; & " + quote(entry) + " python " + quote(edit_script) + " " + quote(output) + " " + quote(edited)
                    ps += "; if ($LASTEXITCODE -ne 0) { throw 'edit failed' }; & " + quote(entry) + " python " + quote(entry.parent / "read.py") + " " + quote(edited) + " " + quote(work / "read.json")
                    ps += "; if ($LASTEXITCODE -ne 0) { throw 'read failed' }; Write-Output '" + marker + "'"
                    encoded = base64.b64encode(ps.encode("utf-16-le")).decode()
                    response = sse({"command": "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + encoded, "timeout": 120000})
                else:
                    assert state["calls"] == 2
                    results = [c for m in payload["messages"] for c in m.get("content", []) if isinstance(c, dict) and c.get("type") == "tool_result"]
                    assert results and not results[-1].get("is_error"), results
                    assert marker in "\n".join(texts(results[-1])), results[-1]
                    response = sse()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)
            except Exception as error:
                state["error"] = repr(error)
                self.send_error(500, "Office fixture assertion failed")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        env = dict(os.environ, LOCALAPPDATA=str(profile), METAWORK_OFFICE_CORE_WORKSPACE=str(work),
                   METAWORK_OFFICE_CORE_SKILLS=str(skills), METAWORK_OFFICE_CORE_SKILL=kind,
                   METAWORK_OFFICE_CORE_URL="http://127.0.0.1:" + str(server.server_port) + "/v1/messages")
        result = subprocess.run([str(probe)], env=env, capture_output=True, timeout=180)
        if result.returncode or state["error"]:
            raise RuntimeError(str(scratch) + "\n" + str(state["error"]) + "\n" + result.stderr.decode("utf-8", errors="replace"))
        assert state["calls"] == 2
        parsed = json.loads((work / "read.json").read_text(encoding="utf-8"))
        assert parsed["format"] == kind and "中文 edited" in json.dumps(parsed, ensure_ascii=False)
        assert output.read_bytes() != edited.read_bytes()
        print(json.dumps({"skill": kind, "materialized_entry": state["entry"], "actual_core_bash": True, "create_edit_read": True,
                          "original_sha256": hashlib.sha256(output.read_bytes()).hexdigest()}, ensure_ascii=True), flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
print("Office Core shell qualification passed: " + str(scratch))
