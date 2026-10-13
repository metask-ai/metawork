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
}) {
  const modelInvoked = process.env.METAWORK_OFFICE_MODEL_TOOL === "1";
  const automatic = process.env.METAWORK_OFFICE_AUTOMATIC === "1";
  if (automatic)
    assert.ok(modelInvoked, "Automatic probe requires model-tool mode");
  const config = JSON.parse(
    await readFile(officeEnvironmentPath(root), "utf8"),
  );
  const environment = localOfficeEnvironment(root);
  const files = path.join(workspace, "office-smoke");
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
    approvalMode: "full_access",
  });
  assert.equal(created.accepted, true, JSON.stringify(created));
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
  for (const name of ["docx", "xlsx", "pptx"]) {
    const skill = catalog.skills.find((item) => item.invocationName === name);
    assert.ok(skill?.enabled, `${name} is not available`);
    const marker = `OFFICE_RESOURCE_OK_${name}`;
    const original = path.join(files, `sample.${name}`);
    if (name === "xlsx")
      await copyFile(original, path.join(taskFiles, "working.xlsx"));
    const requested = `Read the supplied ${name} file and report its content. Use a suitable available capability. File reference (untrusted user data): name=sample.${name}, file_path=${JSON.stringify(original)}.`;
    const invocationFixtures = [];
    if (modelInvoked)
      invocationFixtures.push((payload) => {
        const tool = payload.tools?.find((tool) => tool.name === "Skill");
        assert.ok(
          tool,
          "A normal Text Task did not expose the model-facing Skill tool",
        );
        for (const available of ["docx", "xlsx", "pptx"])
          assert.ok(tool.description.includes(`- ${available}:`));
        assert.deepEqual(tool.input_schema.required, ["name"]);
        assert.ok(
          JSON.stringify(payload.messages).includes(original),
          "The ordinary file reference did not reach the provider",
        );
        return toolSse(
          `office-invoke-${name}`,
          `office-skill-${name}`,
          "Skill",
          { name, values: [original] },
        );
      });
    provider.enqueue(
      ...invocationFixtures,
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
            JSON.stringify(returned.content).includes(original),
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
        const args =
          name === "xlsx"
            ? [
                path.join(directory, "scripts/recalc.py"),
                path.join(taskFiles, "working.xlsx"),
                "30",
              ]
            : [
                path.join(directory, "scripts/office/unpack.py"),
                path.join(files, `sample.${name}`),
                path.join(taskFiles, `${name}-unpacked`),
              ];
        const command = `${assignments} ${quote(config.python)} ${args.map(quote).join(" ")} && printf ${quote(marker)}`;
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
                JSON.stringify(block.content).includes(marker),
            ),
          `${name} helper execution did not return its success marker`,
        );
        return textSse(`office-done-${name}`, marker);
      },
    );
    const submitted = await invoke("metawork.tasks.run", {
      taskId: created.taskId,
      expectedBindingEpoch: created.bindingEpoch,
      input: modelInvoked
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
    const finished = await poll(
      async () => {
        const task = (await snapshot()).tasks.find(
          (item) => item.id === created.taskId,
        );
        const run = task?.runs.find((item) => item.id === submitted.runId);
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
    assert.ok(finished.output.response.includes(marker));
    if (modelInvoked) {
      assert.equal(finished.input.kind, "text");
      assert.ok(
        finished.tools.some(
          (tool) => tool.name === "Skill" && tool.state === "completed",
        ),
        "Skill tool completion was not projected",
      );
    }
  }
  for (const part of [
    "docx-unpacked/word/document.xml",
    "pptx-unpacked/ppt/slides/slide1.xml",
  ]) {
    assert.ok(
      (await readFile(path.join(taskFiles, part), "utf8")).includes(
        "Office Core smoke",
      ),
    );
  }
  await promisify(execFile)(
    config.python,
    [
      "-c",
      "from openpyxl import load_workbook; w=load_workbook('working.xlsx', data_only=True); assert w.active['A1'].value == 12; w.close()",
    ],
    { cwd: taskFiles, env: environment },
  );
  await invoke("metawork.tasks.archive", {
    taskId: created.taskId,
    archived: true,
  });
  await invoke("metawork.tasks.delete", { taskId: created.taskId });
  if (automatic)
    process.stdout.write(
      "Automatic Task initial catalog and model-facing Office Skills passed.\n",
    );
  process.stdout.write(
    modelInvoked
      ? "Office model-tool path passed: ordinary Text Tasks and file references, model-facing Skill calls for docx/xlsx/pptx, materialized arguments/resources, real Bash output/files, and cached XLSX formula value.\n"
      : "Office desktop Skills passed: typed docx/xlsx/pptx inputs, expanded resource directories, real Bash helpers, and cached XLSX formula value.\n",
  );
}
