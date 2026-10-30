"""Native opt-in: canonical Core materializes Skills and executes real Bash calls.

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
import shlex
import sys
import subprocess
import tempfile
import threading
import zipfile

import office_qualification as qualification

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--profile", type=Path)
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--home-probe", action="store_true", help="Check actual Core Bash HOME in two independent workspaces; no private environment needed")
mode.add_argument("--permission-probe", action="store_true", help="Check default deny/allow-once and full-access through the same materialized entry")
qualification.target_option(parser)
args = parser.parse_args()
qualification.require_native(parser, args.target)
if not args.home_probe and args.profile is None:
    parser.error("--profile is required for document qualification")
profile = args.profile.resolve(strict=True) if args.profile else Path.home().resolve()
def inventory():
    return {str(p.relative_to(qualification.dependency_root(profile))): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in qualification.dependency_root(profile).rglob("*") if p.is_file()}

before_environment = inventory() if not args.home_probe else None
scratch = Path(tempfile.mkdtemp(prefix="office-core shell ", dir=REPO / ".zig-cache"))
skills = scratch / "skills"
skills.mkdir()
qualification.extract(REPO / "src/app/office-skills.tar.gz", skills)
probe = REPO / (".zig-cache/office-core-qualification/bin/office-skill-shell" + (".exe" if sys.platform == "win32" else ""))


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


for case in (("deny", "allow", "full") if args.permission_probe else (("docx", "xlsx") if args.home_probe else ("docx", "xlsx", "pptx"))):
    kind = "xlsx" if args.permission_probe else case
    work = scratch / case
    work.mkdir()
    output = work / ("created." + kind)
    generator_output = work / "generated.pptx" if kind == "pptx" else output
    edited = work / ("edited." + kind)
    edit_script = work / "edit.py"
    edit_script.write_text('''import sys,zipfile,hashlib
from pathlib import Path
from office_archive import checked_copy
from lxml import etree
source,destination=map(Path,sys.argv[1:])
original_digest=hashlib.sha256(source.read_bytes()).hexdigest()
with checked_copy(source) as checked,zipfile.ZipFile(checked) as original,zipfile.ZipFile(destination,"x",compression=zipfile.ZIP_DEFLATED) as changed:
 for member in original.infolist():
  content=original.read(member)
  if member.filename.endswith(".xml"):
   root=etree.fromstring(content)
   for element in root.iter():
    if element.text and "Office 中文" in element.text: element.text=element.text.replace("Office 中文","Office 中文 edited")
   content=etree.tostring(root,encoding="UTF-8",xml_declaration=True)
  changed.writestr(member,content)
assert hashlib.sha256(source.read_bytes()).hexdigest()==original_digest
''', encoding="utf-8")
    marker = "office-" + kind + "-materialized-ok"
    if kind == "xlsx":
        language = "python"
        script = work / "create.py"
        script.write_text('from openpyxl import Workbook\nimport sys\nw=Workbook();w.active["A1"]="Office 中文";w.active["B1"]="=1+2";w.save(sys.argv[1])\n', encoding="utf-8")
        checks = [{"id": "text", "op": "values", "target": {"sheet": "Sheet", "range": "A1"},
                   "expected": [[{"type": "string", "value": "Office 中文 edited"}]]},
                  {"id": "formula", "op": "values", "target": {"sheet": "Sheet", "range": "B1"},
                   "expected": [[{"type": "formula", "value": "=1+2"}]]}]
        (work / "checks.json").write_text(json.dumps({"version": 1, "checks": checks, "requirements": [
            {"id": "content", "source": "Fixed fixture edit and unchanged formula", "checks": ["text", "formula"]}]}), encoding="utf-8")
    else:
        language = "node"
        script = work / "scripts" / "create.cjs"
        script.parent.mkdir()
        code = ('const fs=require("node:fs"),{Document,Packer,Paragraph}=require("docx");'
                'Packer.toBuffer(new Document({sections:[{children:[new Paragraph("Office 中文")]}]})).then(b=>fs.writeFileSync(process.argv[2],b));') if kind == "docx" else (
                'const P=require("pptxgenjs");const p=new P();const s=p.addSlide();'
                's.addText("Office 中文",{x:1,y:0.2,w:8,h:0.5});s.addNotes("Core notes 650");'
                's.addChart(p.ChartType.bar,[{name:"Amount",labels:["North","South"],values:[300,350]}],'
                '{x:1,y:1,w:8,h:4,showValue:true,chartColors:["0D9488","14B8A6"]});'
                'p.writeFile({fileName:process.argv[2]});')
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
                if state["calls"] == 1 and args.home_probe:
                    if sys.platform == "win32":
                        raise RuntimeError("HOME probe currently exercises POSIX Bash")
                    command = '/usr/bin/printf %s "$HOME" > ' + shlex.quote(str(work / "home.txt")) + ' && /usr/bin/printf %s ' + shlex.quote(marker)
                    response = sse({"command": command, "timeout": 10000})
                elif state["calls"] == 1:
                    content = "\n".join(texts(payload))
                    pattern = r"[A-Za-z]:[\\/][^`\"\r\n<>]+?[\\/]environment[\\/]run\.cmd" if sys.platform == "win32" else r"/[^`\"\r\n<>]+?/environment/run\.sh"
                    candidates = re.findall(pattern, content)
                    existing = [Path(p) for p in candidates if Path(p).is_file()]
                    if not existing:
                        raise AssertionError("No expanded absolute run entry in materialized Skill; inspect request-0.json")
                    entry = existing[-1]
                    assert not entry.is_relative_to(skills), "Core used original source, not materialized resources"
                    state["entry"] = str(entry)
                    if sys.platform == "win32":
                        def quote(value):
                            return "'" + str(value).replace("'", "''") + "'"
                        ps = "$ErrorActionPreference='Stop'; & " + quote(entry) + " " + language + " " + quote(script.relative_to(work)) + " " + quote(generator_output)
                        if kind == "pptx":
                            ps += "; if ($LASTEXITCODE -ne 0) { throw 'generate failed' }; & " + quote(entry) + " python " + quote(entry.parent.parent / "scripts/finalize.py") + " " + quote(generator_output) + " " + quote(output)
                        ps += "; if ($LASTEXITCODE -ne 0) { throw 'create failed' }; & " + quote(entry) + " python " + quote(edit_script) + " " + quote(output) + " " + quote(edited)
                        ps += "; if ($LASTEXITCODE -ne 0) { throw 'edit failed' }; & " + quote(entry) + " python " + quote(entry.parent / "read.py") + " " + quote(edited) + " " + quote(work / "read.json")
                        ps += "; if ($LASTEXITCODE -ne 0) { throw 'read failed' }"
                        if kind == "xlsx":
                            ps += "; & " + quote(entry) + " python " + quote(entry.parent.parent / "scripts/verify.py") + " " + quote(edited) + " " + quote(work / "verification.json") + " --checks " + quote(work / "checks.json")
                            ps += "; if ($LASTEXITCODE -ne 0) { throw 'verification failed' }"
                        if kind == "pptx":
                            ps += "; & " + quote(entry) + " python " + quote(entry.parent.parent / "scripts/office/validate.py") + " " + quote(edited)
                            ps += "; if ($LASTEXITCODE -ne 0) { throw 'structure failed' }"
                        ps += "; Write-Output '" + marker + "'"
                        encoded = base64.b64encode(ps.encode("utf-16-le")).decode()
                        response = sse({"command": "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + encoded, "timeout": 120000})
                    else:
                        calls = [["/bin/sh", entry, language, script.relative_to(work), generator_output]]
                        if kind == "pptx":
                            calls.append(["/bin/sh", entry, "python", entry.parent.parent / "scripts/finalize.py", generator_output, output])
                        calls.extend([["/bin/sh", entry, "python", edit_script, output, edited],
                                      ["/bin/sh", entry, "python", entry.parent / "read.py", edited, work / "read.json"]])
                        if kind == "xlsx":
                            calls.append(["/bin/sh", entry, "python", entry.parent.parent / "scripts/verify.py", edited, work / "verification.json", "--checks", work / "checks.json"])
                        if kind == "pptx":
                            calls.append(["/bin/sh", entry, "python", entry.parent.parent / "scripts/office/validate.py", edited])
                        command = " && ".join(" ".join(shlex.quote(str(a)) for a in call) for call in calls)
                        command += " && /usr/bin/printf %s " + shlex.quote(marker)
                        response = sse({"command": command, "timeout": 120000})
                else:
                    assert state["calls"] == 2
                    results = [c for m in payload["messages"] for c in m.get("content", []) if isinstance(c, dict) and c.get("type") == "tool_result"]
                    assert results, results
                    if args.permission_probe and case == "deny":
                        assert results[-1].get("is_error"), results[-1]
                        assert marker not in "\n".join(texts(results[-1])), results[-1]
                    else:
                        assert not results[-1].get("is_error"), results
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
        env = dict(qualification.environment(profile) if not args.home_probe else os.environ, METAWORK_OFFICE_CORE_WORKSPACE=str(work),
                   METAWORK_OFFICE_CORE_HOME=str(Path.home().resolve()) if args.home_probe else str(profile if sys.platform == "darwin" else Path.home().resolve()),
                   METAWORK_OFFICE_CORE_SKILLS=str(skills), METAWORK_OFFICE_CORE_SKILL=kind,
                   METAWORK_OFFICE_CORE_URL="http://127.0.0.1:" + str(server.server_port) + "/v1/messages")
        env.pop("METAWORK_OFFICE_CORE_PERMISSION_CASE", None)
        if args.permission_probe:
            env["METAWORK_OFFICE_CORE_PERMISSION_CASE"] = case
        result = subprocess.run([str(probe)], env=env, capture_output=True, timeout=180)
        if result.returncode or state["error"]:
            raise RuntimeError(str(scratch) + "\n" + str(state["error"]) + "\n" + result.stderr.decode("utf-8", errors="replace"))
        assert state["calls"] == 2
        if args.permission_probe:
            expected = 0 if case == "full" else 1
            assert "Office permission callbacks: " + str(expected) in result.stderr.decode("utf-8", errors="replace")
            if case == "deny":
                assert not output.exists() and not edited.exists() and not (work / "read.json").exists(), "Denied Shell executed a document operation"
                assert not (work / "verification.json").exists(), "Denied Shell produced a verification report"
                assert inventory() == before_environment, "Denied Shell changed the private environment"
                print(json.dumps({"permission": case, "callbacks": expected, "no_execution": True, "environment_unchanged": True}), flush=True)
                continue
        if args.home_probe:
            actual = (work / "home.txt").read_text(encoding="utf-8")
            assert actual == str(Path.home().resolve()), (actual, Path.home())
            print(json.dumps({"workspace": str(work), "shell_home": actual, "canonical_home": str(Path.home().resolve()), "actual_core_bash": True}), flush=True)
            continue
        parsed = json.loads((work / "read.json").read_text(encoding="utf-8"))
        assert parsed["format"] == kind and "中文 edited" in json.dumps(parsed, ensure_ascii=False)
        assert output.read_bytes() != edited.read_bytes()
        if kind == "xlsx":
            cell = next(c for sheet in parsed["sheets"] for c in sheet["cells"] if c["cell"] == "B1")
            assert cell["formula"] is True and cell["value"] == "=1+2" and cell["cached"] is None
            verification = json.loads((work / "verification.json").read_text(encoding="utf-8"))
            assert verification["status"] == "passed" and verification["conforms"] is True, verification
            assert verification["candidate"] == {"bytes": edited.stat().st_size, "sha256": hashlib.sha256(edited.read_bytes()).hexdigest()}
        if kind == "pptx":
            with zipfile.ZipFile(edited) as packed:
                assert any(b"Core notes 650" in packed.read(name) for name in packed.namelist()
                           if name.startswith("ppt/notesSlides/") and name.endswith(".xml"))
            assert output.read_bytes() != generator_output.read_bytes(), "PPTX finishing did not run"
        assert inventory() == before_environment, "Core document processing changed the private environment"
        print(json.dumps({"skill": kind, "permission": case if args.permission_probe else "full", "materialized_entry": state["entry"], "actual_core_bash": True, "create_edit_read": True,
                          "original_sha256": hashlib.sha256(output.read_bytes()).hexdigest()}, ensure_ascii=True), flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
print(("Office Core HOME probe passed: " if args.home_probe else "Office Core shell qualification passed: ") + str(scratch))
