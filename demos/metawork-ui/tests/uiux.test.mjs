import test from "node:test";
import assert from "node:assert/strict";
import {
  monthAnchors,
  measuredWindowWidth,
  resolveSkillRoot,
  validateSkillPackage,
} from "../src/demo/uiux-logic.ts";

test("a month sharing its first calendar column is placed in its next available column", () => {
  const days = [
    { date: "2025-10-31", column: 1 },
    { date: "2025-11-01", column: 1 },
    { date: "2025-11-02", column: 2 },
    { date: "2025-11-30", column: 6 },
    { date: "2025-12-01", column: 6 },
    { date: "2025-12-07", column: 7 },
  ];
  assert.deepEqual(
    monthAnchors(days).map((day) => [day.date.slice(0, 7), day.column]),
    [
      ["2025-10", 1],
      ["2025-11", 2],
      ["2025-12", 6],
    ],
  );
});
test("a zero-size or disconnected window keeps the previous measured width", () => {
  assert.equal(measuredWindowWidth(0, 0, 1440), 1440);
  assert.equal(measuredWindowWidth(0, 1024, 1440), 1024);
  assert.equal(measuredWindowWidth(390, 1440, 1440), 390);
});
test("skill roots support extracted outer folders and reject missing or ambiguous definitions", () => {
  assert.equal(resolveSkillRoot(["SKILL.md", "references/guide.md"]), "");
  assert.equal(
    resolveSkillRoot([
      "下载/设计审查/SKILL.md",
      "下载/设计审查/references/a.md",
    ]),
    "下载/设计审查/",
  );
  assert.throws(
    () => resolveSkillRoot(["README.md"]),
    /SKILL_DEFINITION_MISSING/,
  );
  assert.throws(
    () => resolveSkillRoot(["one/SKILL.md", "two/SKILL.md"]),
    /SKILL_MULTIPLE_DEFINITIONS/,
  );
});
test("import manifests reject path traversal and unsupported package types", () => {
  assert.throws(() => resolveSkillRoot(["../SKILL.md"]), /SKILL_INVALID_PATH/);
  assert.throws(
    () => resolveSkillRoot(["/private/SKILL.md"]),
    /SKILL_INVALID_PATH/,
  );
  assert.throws(() => resolveSkillRoot(["a\\SKILL.md"]), /SKILL_INVALID_PATH/);
  assert.doesNotThrow(() => validateSkillPackage("设计.skill"));
  assert.doesNotThrow(() => validateSkillPackage("review.ZIP"));
  assert.throws(
    () => validateSkillPackage("review.txt"),
    /SKILL_UNSUPPORTED_FORMAT/,
  );
});
