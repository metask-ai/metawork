import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";

export function officeEnvironmentPath(root) {
  return path.join(root, ".zig-cache/office-runtime/environment.json");
}

export function readOfficeComponent(directory) {
  if (process.platform !== "win32" || process.arch !== "x64")
    throw new Error(
      "The prepared Office component currently requires Windows x64",
    );
  if (
    typeof directory !== "string" ||
    !path.isAbsolute(directory) ||
    directory.includes("\0")
  )
    throw new Error("Office component must be an absolute directory");
  const root = realpathSync(directory);
  const manifestPath = path.join(root, "office-runtime.json");
  if (
    !lstatSync(manifestPath).isFile() ||
    lstatSync(manifestPath).size > 8 * 1024 * 1024
  )
    throw new Error("Office component manifest is invalid");
  const bytes = readFileSync(manifestPath);
  const manifest = JSON.parse(bytes);
  if (
    manifest.schema !== 1 ||
    manifest.target !== "x86_64-windows-msvc" ||
    !Array.isArray(manifest.files)
  )
    throw new Error("Office component manifest target or format is invalid");
  const entry = path.join(root, "bin/office.exe");
  const python = path.join(root, "python/bin/python.exe");
  const skillsRoot = path.join(root, "skills");
  for (const relative of [
    "bin/office.exe",
    "python/bin/python.exe",
    "skills/docx/SKILL.md",
    "skills/xlsx/SKILL.md",
    "skills/pptx/SKILL.md",
  ]) {
    const expected = manifest.files.find((file) => file.path === relative);
    const file = path.join(root, relative);
    if (
      !expected ||
      !lstatSync(file).isFile() ||
      lstatSync(file).isSymbolicLink() ||
      lstatSync(file).size !== expected.bytes ||
      createHash("sha256").update(readFileSync(file)).digest("hex") !==
        expected.sha256
    )
      throw new Error(
        `Prepared Office component resource changed: ${relative}`,
      );
  }
  return {
    root,
    entry,
    python,
    skillsRoot,
    manifest,
    manifestSha256: createHash("sha256").update(bytes).digest("hex"),
  };
}

export function localOfficeComponent(root) {
  const filename = officeEnvironmentPath(root);
  if (!existsSync(filename)) return null;
  if (!lstatSync(filename).isFile() || lstatSync(filename).size > 16 * 1024)
    throw new Error(
      "Local Office component selection is invalid; run office:setup",
    );
  const config = JSON.parse(readFileSync(filename, "utf8"));
  if (
    !config ||
    config.schema !== 2 ||
    Object.keys(config).sort().join(",") !==
      "componentRoot,manifestSha256,schema"
  )
    throw new Error(
      "Local Office component selection is invalid; run office:setup -- --component <absolute-root>",
    );
  const selected = readOfficeComponent(config.componentRoot);
  if (selected.manifestSha256 !== config.manifestSha256)
    throw new Error(
      "Selected Office component changed; run office:setup again",
    );
  return selected;
}

export function localOfficeEnvironment(root, inherited = process.env) {
  const component = localOfficeComponent(root);
  // Only explicit Office commands select these interpreters/libraries. No
  // interpreter search path is injected into ordinary Tasks or custom Skills.
  return component
    ? { ...inherited, METAWORK_LOCAL_SKILL_ROOT: component.skillsRoot }
    : { ...inherited };
}
