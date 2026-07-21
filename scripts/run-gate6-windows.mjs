import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

if (process.platform !== "win32") {
  throw new Error("test:gate6:windows requires Windows");
}

const execFileAsync = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const command = process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
const native = path.join(
  root,
  "node_modules",
  "@native-sdk",
  "cli",
  "bin",
  "native.js",
);

await execFileAsync(command, ["/d", "/s", "/c", "npm run build:frontend"], {
  cwd: root,
  maxBuffer: 16 * 1024 * 1024,
});
await execFileAsync(
  process.execPath,
  [native, "build", ".", "--yes", "-Doptimize=Debug", "-Dautomation=true"],
  { cwd: root, maxBuffer: 16 * 1024 * 1024 },
);
process.env.METAWORK_TEST_APP_CWD = path.join("zig-out", "bin");
await import("./test-gate6-macos.mjs");
