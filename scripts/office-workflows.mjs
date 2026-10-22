import { lstatSync, readFileSync } from "node:fs";
import path from "node:path";

export function officeWorkflowInventory(root) {
  const input = JSON.parse(
    readFileSync(
      path.join(root, "build_support/office-workflows.json"),
      "utf8",
    ),
  );
  if (
    input.schema !== 1 ||
    !Array.isArray(input.skills) ||
    input.skills
      .map((skill) => skill.id)
      .sort()
      .join(",") !== "docx,pptx,xlsx"
  )
    throw new Error(
      "Office workflows must declare exactly docx, xlsx and pptx",
    );
  const pythonPins = new Map(
    readFileSync(path.join(root, "scripts/office-requirements.txt"), "utf8")
      .split(/\r?\n/u)
      .filter(Boolean)
      .map((line) => {
        const match = /^([\w-]+)==([^\s]+)$/u.exec(line);
        if (!match)
          throw new Error(`Unpinned Office Python requirement: ${line}`);
        return [match[1].toLowerCase(), match[2]];
      }),
  );
  const nodePins = JSON.parse(
    readFileSync(path.join(root, "package.json"), "utf8"),
  ).devDependencies;
  const tools = new Set();
  const pythonPackages = new Set();
  const nodePackages = new Set();
  const skills = input.skills.map((skill) => {
    const directory = path.join(root, "src/product/skill/assets", skill.id);
    const helpers = new Set(skill.helpers);
    if (
      !Array.isArray(skill.helpers) ||
      helpers.size !== skill.helpers.length ||
      !Array.isArray(skill.guides) ||
      !skill.guides.includes("SKILL.md") ||
      !Array.isArray(skill.workflows) ||
      skill.workflows.length === 0
    )
      throw new Error(`Invalid Office workflow resources: ${skill.id}`);
    for (const resource of [...skill.guides, ...helpers]) {
      if (
        typeof resource !== "string" ||
        resource.includes("\\") ||
        resource
          .split("/")
          .some((part) => !part || part === "." || part === "..") ||
        path.isAbsolute(resource) ||
        !lstatSync(path.join(directory, resource)).isFile()
      )
        throw new Error(`Invalid Office resource: ${skill.id}/${resource}`);
    }
    for (const guide of skill.guides) {
      const text = readFileSync(path.join(directory, guide), "utf8");
      for (const match of text.matchAll(
        /python(?:3)?\s+(scripts\/[\w./-]+\.py)/gu,
      ))
        if (!helpers.has(match[1]))
          throw new Error(`Undeclared Office helper: ${skill.id}/${match[1]}`);
    }
    const workflowIds = new Set();
    for (const workflow of skill.workflows) {
      if (!workflow.id || workflowIds.has(workflow.id))
        throw new Error(`Invalid Office workflow identity: ${skill.id}`);
      workflowIds.add(workflow.id);
      for (const tool of workflow.tools ?? []) {
        if (!["soffice", "pdftoppm", "pandoc"].includes(tool))
          throw new Error(`Unknown Office tool: ${tool}`);
        tools.add(tool);
      }
      for (const dependency of workflow.pythonPackages ?? []) {
        if (!pythonPins.has(dependency))
          throw new Error(`Unpinned Office Python package: ${dependency}`);
        pythonPackages.add(dependency);
      }
      for (const dependency of workflow.nodePackages ?? []) {
        if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/u.test(nodePins?.[dependency] ?? ""))
          throw new Error(`Unpinned Office Node package: ${dependency}`);
        nodePackages.add(dependency);
      }
    }
    return { ...skill, directory };
  });
  return {
    skills,
    tools: [...tools].sort(),
    pythonPackages: [...pythonPackages]
      .sort()
      .map((name) => ({ name, version: pythonPins.get(name) })),
    nodePackages: [...nodePackages]
      .sort()
      .map((name) => ({ name, version: nodePins[name] })),
  };
}
