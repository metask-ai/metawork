import assert from "node:assert/strict";
import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { officeWorkflowInventory } from "./office-workflows.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));

test("retained Office guide commands have resources and pinned runtime dependencies", () => {
  const inventory = officeWorkflowInventory(root);
  assert.deepEqual(inventory.skills.map((skill) => skill.id).sort(), [
    "docx",
    "pptx",
    "xlsx",
  ]);
  assert.deepEqual(inventory.tools, ["office"]);
  assert.deepEqual(
    inventory.nodePackages.map((entry) => entry.name),
    ["docx", "pptxgenjs"],
  );
});

test("a new guide command cannot silently escape the Office payload inventory", (t) => {
  const scratch = mkdtempSync(
    path.join(os.tmpdir(), "metawork-office-inventory-"),
  );
  t.after(() => rmSync(scratch, { recursive: true, force: true }));
  mkdirSync(path.join(scratch, "build_support"));
  mkdirSync(path.join(scratch, "scripts"));
  for (const file of [
    "build_support/office-workflows.json",
    "scripts/office-requirements.txt",
    "package.json",
  ])
    writeFileSync(
      path.join(scratch, file),
      readFileSync(path.join(root, file)),
    );
  for (const skill of officeWorkflowInventory(root).skills) {
    const directory = path.join(scratch, "src/product/skill/assets", skill.id);
    for (const resource of [...skill.guides, ...skill.helpers]) {
      const destination = path.join(directory, resource);
      mkdirSync(path.dirname(destination), { recursive: true });
      writeFileSync(destination, resource.endsWith(".md") ? "guide" : "helper");
    }
  }
  assert.equal(officeWorkflowInventory(scratch).skills.length, 3);
  writeFileSync(
    path.join(scratch, "src/product/skill/assets/docx/SKILL.md"),
    "python scripts/missing.py input.docx",
  );
  assert.throws(
    () => officeWorkflowInventory(scratch),
    /Undeclared Office helper/u,
  );
});
