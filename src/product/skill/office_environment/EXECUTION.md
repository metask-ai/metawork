## Execution environment

Use only this Skill's fixed private runtimes. Target inputs exist for Windows x64/ARM64 and macOS arm64/x64. Select the native OS and architecture in [environment inputs](environment/environment.json); never choose an interpreter from PATH or infer paths from this Skill's parent directory.

| Platform | Fixed prepare entry | Fixed run entry |
| --- | --- | --- |
| Windows | `"${CLAUDE_SKILL_DIR}/environment/prepare.cmd" python` or `node` | `"${CLAUDE_SKILL_DIR}/environment/run.cmd" python script.py [arguments]` or `node script.cjs [arguments]` |
| macOS | `/bin/sh "${CLAUDE_SKILL_DIR}/environment/prepare.sh" python` or `node` | `/bin/sh "${CLAUDE_SKILL_DIR}/environment/run.sh" python script.py [arguments]` or `node script.cjs [arguments]` |

Use the existing Shell with each argument quoted separately. Resource files need no executable bit. Examples below using `run.cmd` mean the selected absolute run entry above; on macOS always substitute `/bin/sh "${CLAUDE_SKILL_DIR}/environment/run.sh"`. Do not execute `.cmd` on macOS or use a system Node/Python.

Run never downloads. Use it to perform the needed operation and detect a missing environment. Before first preparation, explain the purpose and the selected target's `downloadTotals.python.totalBytes` or `downloadTotals.node.totalBytes` from the environment inputs, then obtain the user's agreement. These totals include interpreter and locked library payloads; indexes, retries and transport overhead are extra, so present an estimated network download. Prepare may download: call it only after consent has been obtained, even for an intended reuse. No arbitrary URL, version, package or root arguments are accepted. Allow 30 minutes per runtime download, 10 minutes for dependency installation and bounded final checks; observe long work through the existing Shell background/output tools.

On macOS, **fresh Node preparation requires the exact private Python already prepared**. It does not download Python implicitly. When Node and its prerequisite are missing, explain their combined download and prepare Python, then Node, after agreement. XLSX-only Python work needs no Node. Completed Node can be reused and run without Python; Python validation or reading of documents separately needs Python. Windows keeps both languages independently preparable. Download agreement does not grant filesystem or Shell permissions: follow the existing approval mechanism if the shared root is outside the Workspace, and explain refusals without changing roots. `full_access` adds no product installation gate.

Environments are shared at `%LOCALAPPDATA%/MetaWork/OfficeDependencies` on Windows and `$HOME/Library/Application Support/MetaWork/OfficeDependencies` on macOS. Do not update, rename, delete or repair completed environments. If an existing directory fails checks, report it unavailable with the exact path from prepare. Explain manual recovery: stop every Task and external script using that directory, exit MetaWork, and confirm no consumers remain. Only then may the user explicitly choose to remove that one directory, reopen MetaWork and agree to preparing again. Never remove the parent, other environments, resources or documents. Rename success does not prove no consumers remain. Preserve interrupted stages whose descendants are not confirmed stopped. Do not install globally, change user package configuration, switch architectures or fall back to system packages. Private dependencies are not a sandbox.

Write scripts, working copies and outputs in the Task Workspace. Use `from office_archive import checked_copy` and load only its private checked path inside the context when passing an existing Office file to a library. Never overwrite an attachment original.

This edition cannot render, export PDF, accept revisions or recalculate formulas. Do not invent visual QA or calculation results. XLSX may request recalculation on open; this does not calculate or populate caches now.

## Read, check and deliver

For bounded structured text, use the selected run entry with `python "${CLAUDE_SKILL_DIR}/environment/read.py" input.docx new-content.json` (also XLSX/PPTX). For XML work, run `scripts/office/` helpers through that same Python entry, using new output directories. Reopen changed content and validate supported structures. Report unsupported features and checks not performed.

Call the Host tool `DeliverFile` with the actual Task Workspace-relative output path, for example `{"path":"results/report.docx"}`. This is a tool call, not a Shell command or text to print. Deliver finished requested files, not temporary XML, scripts or check output.
