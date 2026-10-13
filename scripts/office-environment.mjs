import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

export function officeEnvironmentPath(root) {
  return path.join(root, ".zig-cache", "office-runtime", "environment.json");
}

export function localOfficeEnvironment(root, inherited = process.env) {
  const filename = officeEnvironmentPath(root);
  if (!existsSync(filename)) return { ...inherited };
  const config = JSON.parse(readFileSync(filename, "utf8"));
  if (
    !config ||
    typeof config !== "object" ||
    config.schema !== 1 ||
    Object.keys(config).sort().join(",") !== "python,schema,toolDirectories" ||
    config.python !==
      path.join(
        root,
        ".zig-cache",
        "office-runtime",
        "venv",
        process.platform === "win32" ? "Scripts/python.exe" : "bin/python",
      ) ||
    !existsSync(config.python) ||
    !statSync(config.python).isFile() ||
    !Array.isArray(config.toolDirectories) ||
    config.toolDirectories.some(
      (directory) =>
        typeof directory !== "string" ||
        !path.isAbsolute(directory) ||
        !existsSync(directory) ||
        !statSync(directory).isDirectory(),
    )
  )
    throw new Error(
      "Local Office environment is invalid; run scripts/setup-office-environment.mjs again.",
    );
  return {
    ...inherited,
    PATH: [
      path.dirname(config.python),
      ...config.toolDirectories,
      path.dirname(process.execPath),
      inherited.PATH,
    ]
      .filter(Boolean)
      .join(path.delimiter),
    NODE_PATH: path.join(root, "node_modules"),
    PYTHONDONTWRITEBYTECODE: "1",
  };
}
