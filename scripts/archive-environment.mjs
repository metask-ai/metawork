import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

export function archiveEnvironmentPath(root) {
  return path.join(root, ".zig-cache", "archive-runtime", "environment.json");
}

export function archiveHelperPath(root) {
  return path.join(
    root,
    "src",
    "product",
    "control",
    "resources",
    "archive.py",
  );
}

export function localArchiveEnvironment(root, inherited = process.env) {
  const result = { ...inherited };
  // The checkout configuration is the only development-launch input. Never
  // accidentally advertise a helper inherited from a different checkout.
  delete result.METAWORK_LOCAL_ARCHIVE_PYTHON;
  delete result.METAWORK_LOCAL_ARCHIVE_HELPER;
  const filename = archiveEnvironmentPath(root);
  if (!existsSync(filename)) return result;
  if (!statSync(filename).isFile() || statSync(filename).size > 16 * 1024)
    throw new Error("Local archive environment is invalid; run archive:setup.");
  const config = JSON.parse(readFileSync(filename, "utf8"));
  const helper = archiveHelperPath(root);
  if (
    !config ||
    config.schema !== 1 ||
    Object.keys(config).sort().join(",") !== "python,schema" ||
    typeof config.python !== "string" ||
    !path.isAbsolute(config.python) ||
    config.python.includes("\0") ||
    Buffer.byteLength(config.python) > 4096 ||
    !existsSync(config.python) ||
    !statSync(config.python).isFile() ||
    !existsSync(helper) ||
    !statSync(helper).isFile()
  )
    throw new Error("Local archive environment is invalid; run archive:setup.");
  return {
    ...result,
    METAWORK_LOCAL_ARCHIVE_PYTHON: config.python,
    METAWORK_LOCAL_ARCHIVE_HELPER: helper,
  };
}
