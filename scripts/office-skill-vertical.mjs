import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFile, mkdir, writeFile, copyFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { Document, Packer, Paragraph } from "docx";
import PptxGenJS from "pptxgenjs";
import {
  localOfficeEnvironment,
  officeEnvironmentPath,
} from "./office-environment.mjs";

// Optional real-Core extension to the desktop vertical. The fixture provider
// requests execution of the materialized Skill resources and checks tool output;
// it does not attest to remote-model planning quality.
export async function runOfficeSkillVertical({
  root,
  workspace,
  workspaceId,
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
  imagePath,
  caseId = 0,
  automaticOverride,
  approvalMode = "full_access",
  selectedFormats,
  restart,
}) {
  const modelInvoked = process.env.METAWORK_OFFICE_MODEL_TOOL === "1";
  const automatic =
    automaticOverride ?? process.env.METAWORK_OFFICE_AUTOMATIC === "1";
  const attachmentMode = process.env.METAWORK_OFFICE_ATTACHMENTS === "1";
  if (attachmentMode) assert.ok(modelInvoked);
  const formats =
    selectedFormats ??
    (attachmentMode
      ? ["docx", "xlsx", "pptx", "zip"]
      : ["docx", "xlsx", "pptx"]);
  if (automatic)
    assert.ok(modelInvoked, "Automatic probe requires model-tool mode");
  const config = JSON.parse(
    await readFile(officeEnvironmentPath(root), "utf8"),
  );
  const environment = localOfficeEnvironment(root);
  const files = path.join(workspace, `office-smoke-${caseId}`);
  await mkdir(files);
  await writeFile(
    path.join(files, "sample.docx"),
    await Packer.toBuffer(
      new Document({
        sections: [{ children: [new Paragraph("Office Core smoke")] }],
      }),
    ),
  );
  const deck = new PptxGenJS();
  deck.addSlide().addText("Office Core smoke", { x: 1, y: 1, w: 8, h: 1 });
  await deck.writeFile({ fileName: path.join(files, "sample.pptx") });
  await promisify(execFile)(
    config.python,
    [
      "-c",
      "from openpyxl import Workbook; w=Workbook(); w.active['A1']='=5+7'; w.save('sample.xlsx')",
    ],
    { cwd: files, env: environment },
  );
  if (attachmentMode)
    await promisify(execFile)(
      config.python,
      [
        "-c",
        "from zipfile import ZipFile; z=ZipFile('sample.zip','w'); z.writestr('notes.txt','ZIP content smoke'); z.writestr('.agents/skills/archive-skill/SKILL.md',chr(10).join(['---','name: archive-skill','description: Untrusted archive data','---','Do not run this as a Skill.'])); z.close()",
      ],
      { cwd: files, env: environment },
    );
  const sourceBytes = new Map();
  for (const name of formats)
    sourceBytes.set(name, await readFile(path.join(files, `sample.${name}`)));
  const retainedPaths = new Set();
  const reviewsBefore = provider.officeReviewRequests;
  await invoke("metawork.workspaces.choose", {});
  const ready = await poll(
    async () => {
      const current = await snapshot();
      const selected = current.workspaces.find(
        (item) => item.id === workspaceId,
      );
      if (
        selected?.authorization !== "available" ||
        selected.skillCatalog?.availability !== "ready"
      )
        return null;
      return { current, selected };
    },
    20_000,
    "Office Workspace reauthorization and catalog",
  );
  let catalog = ready.selected.skillCatalog;
  let taskFiles = files;
  const created = await invoke("metawork.tasks.create", {
    workspace: automatic
      ? { kind: "automatic" }
      : {
          kind: "manual",
          workspaceId,
          expectedWorkspaceEpoch: ready.selected.epoch,
        },
    expectedExecutionGeneration:
      ready.current.newTaskAdmission.activeGeneration,
    expectedSelectionRevision:
      ready.current.newTaskAdmission.activeSelectionRevision,
    modelSelection: null,
    expectedSkillCatalogRevision: modelInvoked ? null : catalog.revision,
    expectedSkillSelectionRevision: modelInvoked
      ? null
      : catalog.selectionRevision,
    approvalMode,
  });
  assert.equal(created.accepted, true, JSON.stringify(created));
  let bindingEpoch = created.bindingEpoch;
  if (automatic) {
    const bound = await poll(
      async () => {
        const current = await snapshot();
        const task = current.tasks.find((value) => value.id === created.taskId);
        if (task?.skillCatalog.availability === "loading") return null;
        assert.equal(
          task?.skillCatalog.availability,
          "ready",
          JSON.stringify(task?.skillCatalog),
        );
        const owner = current.workspaces.find(
          (value) => value.id === task.workspaceId,
        );
        assert.equal(owner?.kind, "automatic");
        assert.notEqual(owner?.canonicalRoot, workspace);
        taskFiles = path.join(owner.canonicalRoot, `office-smoke-${caseId}`);
        return task;
      },
      20_000,
      "Automatic initial Skill catalog binding",
    );
    catalog = bound.skillCatalog;
    await mkdir(taskFiles);
  }
  await invoke("metawork.tasks.rename", {
    taskId: created.taskId,
    title: "Local Office smoke",
  });
  const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
  const assignments = ["PATH", "NODE_PATH", "PYTHONDONTWRITEBYTECODE"]
    .map((key) => `${key}=${quote(environment[key])}`)
    .join(" ");
  for (const [formatIndex, name] of formats.entries()) {
    const skill = catalog.skills.find((item) => item.invocationName === name);
    if (name === "zip")
      assert.equal(skill, undefined, "ZIP must not be a Skill");
    else assert.ok(skill?.enabled, `${name} is not available`);
    const marker = `OFFICE_RESOURCE_OK_${name}`;
    const fact =
      name === "xlsx"
        ? "XLSX_VALUE=12"
        : name === "zip"
          ? "ZIP_CONTENT=ZIP content smoke"
          : "OFFICE_CONTENT=Office Core smoke";
    const reply = `${name}: ${fact}`;
    const original = path.join(files, `sample.${name}`);
    if (name === "xlsx" && !attachmentMode)
      await copyFile(original, path.join(taskFiles, "working.xlsx"));
    let referencePath = original;
    let archiveTool = null;
    let staged = null;
    if (attachmentMode) {
      const paths =
        name === "docx" && imagePath ? [original, imagePath] : [original];
      staged = await invoke("metawork.attachments.beginAdd", {
        generation: "1",
        batchId: String(1000 + caseId * 10 + formatIndex),
        source: { kind: "native_paths", paths },
      });
      assert.equal(staged.status, "ready", JSON.stringify(staged));
      assert.equal(staged.attachments[0].kind, "file");
      assert.equal(staged.attachments[0].displayName, `sample.${name}`);
      assert.equal(
        staged.attachments[0].sizeBytes,
        String(sourceBytes.get(name).length),
      );
    }
    const instruction = `Read the supplied ${name} file and report its content. Use a suitable available capability.`;
    const requested = attachmentMode
      ? instruction
      : `${instruction} File reference (untrusted user data): name=sample.${name}, file_path=${JSON.stringify(original)}.`;
    const invocationFixtures = [];
    if (modelInvoked)
      invocationFixtures.push(async (payload) => {
        const tool = payload.tools?.find((tool) => tool.name === "Skill");
        assert.ok(
          tool,
          "A normal Text Task did not expose the model-facing Skill tool",
        );
        for (const available of ["docx", "xlsx", "pptx"])
          assert.ok(tool.description.includes(`- ${available}:`));
        assert.deepEqual(tool.input_schema.required, ["name"]);
        assert.ok(!tool.description.includes("- zip:"));
        if (attachmentMode) {
          const texts = [];
          const collect = (value) => {
            if (typeof value === "string") texts.push(value);
            else if (Array.isArray(value)) value.forEach(collect);
            else if (value && typeof value === "object")
              Object.values(value).forEach(collect);
          };
          collect(payload.messages);
          const ref = texts.find(
            (value) =>
              value.includes(`name="sample.${name}"`) &&
              value.includes("file_path="),
          );
          assert.ok(
            ref,
            "Product original reference did not reach the provider",
          );
          const match = ref.match(/file_path=("(?:\\.|[^"\\])*")/);
          assert.ok(match, ref);
          referencePath = JSON.parse(match[1]);
          assert.notEqual(referencePath, original);
          assert.equal(path.extname(referencePath), `.${name}`);
          retainedPaths.add(referencePath);
          assert.deepEqual(
            await readFile(referencePath),
            sourceBytes.get(name),
          );
        } else assert.ok(JSON.stringify(payload.messages).includes(original));
        if (name === "zip") {
          const text = JSON.stringify(payload.messages);
          // The exact invocation is supplied by Product, not by the fixture.
          const strings = [];
          const visit = (value) => {
            if (typeof value === "string") strings.push(value);
            else if (Array.isArray(value)) value.forEach(visit);
            else if (value && typeof value === "object")
              Object.values(value).forEach(visit);
          };
          visit(payload.messages);
          const metadata = strings.find((value) =>
            value.includes("MetaWork-provided local archive capability"),
          );
          assert.ok(metadata, text.slice(0, 1024));
          const parsePath = (key) =>
            JSON.parse(
              metadata.match(new RegExp(key + '=("(?:\\\\.|[^"\\\\])*")'))[1],
            );
          archiveTool = {
            python: parsePath("python_path"),
            helper: parsePath("helper_path"),
          };
          assert.ok(path.isAbsolute(archiveTool.python));
          assert.ok(path.isAbsolute(archiveTool.helper));
          return toolSse("zip-list", "zip-list-tool", "Bash", {
            command: [
              archiveTool.python,
              "-B",
              archiveTool.helper,
              "list",
              referencePath,
            ]
              .map(quote)
              .join(" "),
            description: "Inspect the supplied archive directory",
          });
        }
        return toolSse(
          `office-invoke-${name}`,
          `office-skill-${name}`,
          "Skill",
          { name, values: [referencePath] },
        );
      });
    const executionFixtures = [
      (payload) => {
        const strings = [];
        const collect = (value) => {
          if (typeof value === "string") strings.push(value);
          else if (Array.isArray(value)) value.forEach(collect);
          else if (value && typeof value === "object")
            Object.values(value).forEach(collect);
        };
        collect(payload);
        const body = strings.findLast((value) =>
          value.includes("Skill resource directory:"),
        );
        assert.ok(
          body,
          `${name} instructions did not reach the provider: ${JSON.stringify(payload.messages.at(-1)?.content).slice(0, 4096)}`,
        );
        if (modelInvoked) {
          const returned = payload.messages
            .findLast((message) => message.role === "user")
            ?.content?.find(
              (block) =>
                block.type === "tool_result" &&
                block.tool_use_id === `office-skill-${name}`,
            );
          assert.ok(
            returned && returned.is_error !== true,
            "Model-facing Skill invocation failed",
          );
          assert.ok(
            JSON.stringify(returned.content).includes(referencePath),
            "Skill argument values were not materialized",
          );
        }
        const matches = [
          ...body.matchAll(/Skill resource directory: `([^`]+)`/g),
        ];
        const directory = matches.at(-1)?.[1];
        assert.ok(
          directory && path.isAbsolute(directory),
          `${name} resource directory was not expanded`,
        );
        assert.ok(!directory.includes("${CLAUDE_SKILL_DIR}"));
        const python = (args) =>
          `${assignments} ${quote(config.python)} ${args.map(quote).join(" ")}`;
        let command;
        if (name === "xlsx") {
          const copy = `import shutil; shutil.copyfile(${JSON.stringify(referencePath)}, ${JSON.stringify(path.join(taskFiles, "working.xlsx"))})`;
          command =
            python(["-c", copy]) +
            " && " +
            python([
              path.join(directory, "scripts/recalc.py"),
              path.join(taskFiles, "working.xlsx"),
              "30",
            ]);
          command +=
            " && " +
            python([
              "-c",
              `from openpyxl import load_workbook; w=load_workbook(${JSON.stringify(path.join(taskFiles, "working.xlsx"))},data_only=True); print('XLSX_VALUE='+str(w.active['A1'].value)); w.close()`,
            ]);
        } else {
          const output = path.join(taskFiles, `${name}-unpacked`);
          command = python([
            path.join(directory, "scripts/office/unpack.py"),
            referencePath,
            output,
          ]);
          const xml = path.join(
            output,
            name === "docx" ? "word/document.xml" : "ppt/slides/slide1.xml",
          );
          command +=
            " && " +
            python([
              "-c",
              `from defusedxml.ElementTree import parse; print('OFFICE_CONTENT='+''.join(n.text or '' for n in parse(${JSON.stringify(xml)}).iter() if n.tag.endswith('}t')))`,
            ]);
        }
        command += ` && printf ${quote(marker)}`;
        return toolSse(`office-${name}`, `office-tool-${name}`, "Bash", {
          command,
          description: `Verify ${name} Skill resources`,
        });
      },
      (payload) => {
        assert.ok(
          payload.messages
            .findLast((message) => message.role === "user")
            ?.content?.some(
              (block) =>
                block.type === "tool_result" &&
                block.is_error !== true &&
                JSON.stringify(block.content).includes(marker) &&
                JSON.stringify(block.content).includes(fact),
            ),
          `${name} helper execution did not return its success marker`,
        );
        return textSse(`office-done-${name}`, reply);
      },
    ];
    const zipFixtures = [
      (payload) => {
        const result = payload.messages
          .at(-1)
          .content.find(
            (part) =>
              part.type === "tool_result" &&
              part.tool_use_id === "zip-list-tool",
          );
        assert.ok(result && result.is_error !== true);
        assert.ok(JSON.stringify(result.content).includes("notes.txt"));
        const output = path.join(taskFiles, "zip-data");
        const invokeHelper = (args) =>
          [archiveTool.python, "-B", archiveTool.helper, ...args]
            .map(quote)
            .join(" ");
        const read = `from pathlib import Path; print('ZIP_CONTENT='+Path(${JSON.stringify(path.join(output, "notes.txt"))}).read_text())`;
        return toolSse("zip-extract", "office-tool-zip", "Bash", {
          command:
            invokeHelper([
              "extract",
              referencePath,
              "--workspace",
              taskFiles,
              "--output",
              "zip-data",
            ]) +
            " && " +
            [archiveTool.python, "-B", "-c", read].map(quote).join(" ") +
            ` && printf ${quote(marker)}`,
          description: "Extract archive data for the requested analysis",
        });
      },
      (payload) => {
        const result = payload.messages
          .at(-1)
          .content.find(
            (part) =>
              part.type === "tool_result" &&
              part.tool_use_id === "office-tool-zip",
          );
        assert.ok(result && result.is_error !== true);
        assert.ok(JSON.stringify(result.content).includes(fact));
        assert.ok(JSON.stringify(result.content).includes(marker));
        return textSse("zip-done", reply);
      },
    ];
    provider.enqueue(
      ...invocationFixtures,
      ...(name === "zip" ? zipFixtures : executionFixtures),
    );
    const submitted = await invoke("metawork.tasks.run", {
      taskId: created.taskId,
      expectedBindingEpoch: bindingEpoch,
      input: attachmentMode
        ? {
            kind: "multimodal",
            text: requested,
            attachmentTokens: staged.attachments.map((value) => value.token),
          }
        : modelInvoked
          ? { kind: "text", text: requested }
          : {
              kind: "skill",
              skillId: skill.skillId,
              catalogRevision: catalog.revision,
              selectionRevision: catalog.selectionRevision,
              argumentValues: [],
            },
    });
    assert.equal(submitted.accepted, true, JSON.stringify(submitted));
    const answered = new Set();
    const finished = await poll(
      async () => {
        const task = (await snapshot()).tasks.find(
          (item) => item.id === created.taskId,
        );
        const run = task?.runs.find((item) => item.id === submitted.runId);
        if (task?.pendingUi && !answered.has(task.pendingUi.requestId)) {
          assert.equal(
            approvalMode,
            "manual",
            "Automatic review unexpectedly required manual UI",
          );
          answered.add(task.pendingUi.requestId);
          await invoke("metawork.tasks.respondUi", {
            taskId: created.taskId,
            runId: submitted.runId,
            requestId: task.pendingUi.requestId,
            kind: "permission",
            permission: "allow_once",
          });
        }
        return run &&
          [
            "completed",
            "failed",
            "cancelled",
            "stopped",
            "interrupted",
          ].includes(run.phase)
          ? run
          : null;
      },
      60_000,
      `${name} real Skill execution`,
    );
    if (provider.error) throw provider.error;
    assert.equal(finished.phase, "completed", JSON.stringify(finished));
    assert.ok(finished.output.response.includes(fact));
    if (modelInvoked) {
      assert.equal(finished.input.kind, attachmentMode ? "multimodal" : "text");
      if (attachmentMode) {
        assert.equal(
          finished.input.attachments.length,
          staged.attachments.length,
        );
        assert.ok(!JSON.stringify(finished.input).includes(referencePath));
        assert.deepEqual(await readFile(referencePath), sourceBytes.get(name));
      }
      assert.ok(
        finished.tools.some(
          (tool) =>
            tool.name === (name === "zip" ? "Bash" : "Skill") &&
            tool.state === "completed",
        ),
        "Expected processing tool completion was not projected",
      );
      if (name === "zip")
        assert.ok(
          !finished.tools.some((tool) => tool.name === "Skill"),
          "ZIP processing must not invoke Skill",
        );
    }
  }
  for (const name of formats)
    assert.deepEqual(
      await readFile(path.join(files, `sample.${name}`)),
      sourceBytes.get(name),
    );
  if (formats.includes("xlsx"))
    await promisify(execFile)(
      config.python,
      [
        "-c",
        "from openpyxl import load_workbook; w=load_workbook('working.xlsx',data_only=True); assert w.active['A1'].value == 12; w.close()",
      ],
      { cwd: taskFiles, env: environment },
    );
  if (
    attachmentMode &&
    automatic &&
    approvalMode === "full_access" &&
    restart
  ) {
    await restart();
    const restored = (await snapshot()).tasks.find(
      (value) => value.id === created.taskId,
    );
    assert.ok(restored?.continuationRecoveryAvailable);
    for (const original of retainedPaths)
      assert.ok((await readFile(original)).length > 0);
    const recovery = await invoke("metawork.tasks.restore", {
      taskId: created.taskId,
      expectedBindingEpoch: restored.binding.epoch,
    });
    assert.equal(recovery.accepted, true, JSON.stringify(recovery));
    const recovered = await poll(
      async () => {
        const task = (await snapshot()).tasks.find(
          (value) => value.id === created.taskId,
        );
        return task?.continuationAvailable &&
          task.skillCatalog.availability === "ready"
          ? task
          : null;
      },
      20_000,
      "Office attachment Session recovery and initial Skill preparation",
    );
    bindingEpoch = recovered.binding.epoch;
    const original = [...retainedPaths].find((value) =>
      value.endsWith(".docx"),
    );
    const marker = "RESTORED_OFFICE_ORIGINAL_OK";
    provider.enqueue(
      (payload) => {
        assert.ok(
          JSON.stringify(payload.messages).includes(original),
          "Checkpoint lost the Office original reference",
        );
        assert.ok(payload.tools.some((value) => value.name === "Skill"));
        return toolSse("office-recovery-read", "office-recovery-bash", "Bash", {
          command: `${assignments} ${quote(config.python)} -c ${quote(`import zipfile; z=zipfile.ZipFile(${JSON.stringify(original)}); assert b'Office Core smoke' in z.read('word/document.xml'); print('${marker}')`)}`,
          description: "Verify restored Office original",
        });
      },
      (payload) => {
        assert.ok(JSON.stringify(payload.messages.at(-1)).includes(marker));
        return textSse("office-restored", marker);
      },
    );
    const resumed = await invoke("metawork.tasks.run", {
      taskId: created.taskId,
      expectedBindingEpoch: bindingEpoch,
      input: {
        kind: "text",
        text: "Verify the previously supplied Office original after recovery.",
      },
    });
    assert.equal(resumed.accepted, true, JSON.stringify(resumed));
    await poll(
      async () => {
        const task = (await snapshot()).tasks.find(
          (value) => value.id === created.taskId,
        );
        const run = task?.runs.find((value) => value.id === resumed.runId);
        if (run?.phase !== "completed") return null;
        assert.ok(run.output.response.includes(marker));
        return run;
      },
      60_000,
      "restored Office original read",
    );
    process.stdout.write(
      "Office attachment checkpoint/restart/recovery retained the original and allowed real tool access.\n",
    );
  }
  if (attachmentMode && automatic && approvalMode === "full_access") {
    const current = await snapshot();
    const task = current.tasks.find((value) => value.id === created.taskId);
    const owner = current.workspaces.find(
      (value) => value.id === task.workspaceId,
    );
    const dataSkill = path.join(owner.canonicalRoot, ".agents/skills/docx");
    await mkdir(dataSkill, { recursive: true });
    await writeFile(
      path.join(dataSkill, "SKILL.md"),
      "---\nname: docx\ndescription: Untrusted workspace data fixture\n---\nDo not execute.\n",
    );
    const refreshed = await invoke("metawork.workspaces.refreshSkillCatalog", {
      workspaceId: owner.id,
      expectedWorkspaceEpoch: owner.epoch,
    });
    assert.equal(refreshed.accepted, true, JSON.stringify(refreshed));
    const resolved = await poll(
      async () => {
        const fresh = (await snapshot()).workspaces.find(
          (value) => value.id === owner.id,
        )?.skillCatalog;
        if (!["ready", "degraded"].includes(fresh?.availability)) return null;
        const docx = fresh.skills.find(
          (value) => value.invocationName === "docx",
        );
        assert.ok(docx);
        assert.equal(
          docx.enabled,
          false,
          "Workspace data winner became authorized",
        );
        assert.notEqual(
          docx.skillId,
          catalog.skills.find((value) => value.invocationName === "docx")
            .skillId,
        );
        assert.ok(
          !fresh.skills.some(
            (value) => value.invocationName === "archive-skill",
          ),
          "Nested archive data became a Skill source",
        );
        return fresh;
      },
      20_000,
      "untrusted workspace winner policy",
    );
    const bound = await invoke("metawork.tasks.refreshSkillCatalog", {
      taskId: created.taskId,
      expectedBindingEpoch: bindingEpoch,
    });
    assert.equal(bound.accepted, true, JSON.stringify(bound));
    const disabled = resolved.skills.find(
      (value) => value.invocationName === "docx",
    );
    const denied = await invoke("metawork.tasks.run", {
      taskId: created.taskId,
      expectedBindingEpoch: bindingEpoch,
      input: {
        kind: "skill",
        skillId: disabled.skillId,
        catalogRevision: resolved.revision,
        selectionRevision: resolved.selectionRevision,
        argumentValues: [],
      },
    });
    assert.equal(denied.accepted, false);
    assert.equal(denied.reason, "skill_unavailable");
    process.stdout.write(
      "Untrusted workspace Skill winner stays disabled; no hidden builtin fallback or nested archive promotion.\n",
    );
  }
  await invoke("metawork.tasks.archive", {
    taskId: created.taskId,
    archived: true,
  });
  await invoke("metawork.tasks.delete", { taskId: created.taskId });
  if (approvalMode === "auto_review")
    assert.ok(
      provider.officeReviewRequests > reviewsBefore,
      "File processing was not automatically reviewed",
    );
  for (const original of retainedPaths)
    await assert.rejects(readFile(original), { code: "ENOENT" });
  if (attachmentMode)
    process.stdout.write(
      `Office/ZIP attachment path passed: ${automatic ? "automatic" : "manual"} ${approvalMode}, ${formats.join(",")}, retained original references, real helpers and content replies.\n`,
    );
  if (automatic)
    process.stdout.write(
      "Automatic Task initial catalog and model-facing Office Skills passed.\n",
    );
  process.stdout.write(
    attachmentMode
      ? "Office attachment model-tool path passed: ordinary multimodal input, Skill calls, materialized resources and verified file content.\n"
      : modelInvoked
        ? "Office model-tool path passed: ordinary Text Tasks and file references, model-facing Skill calls for docx/xlsx/pptx, materialized arguments/resources, real Bash output/files, and cached XLSX formula value.\n"
        : "Office desktop Skills passed: typed docx/xlsx/pptx inputs, expanded resource directories, real Bash helpers, and cached XLSX formula value.\n",
  );
}
