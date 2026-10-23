import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  createReadStream,
  existsSync,
  lstatSync,
  mkdirSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  officeEnvironmentPath,
  readOfficeComponent,
} from "./office-environment.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
if (process.argv.length !== 4 || process.argv[2] !== "--component")
  throw new Error(
    "Usage: setup-office-environment.mjs --component <absolute-prepared-component-root>",
  );
const component = readOfficeComponent(process.argv[3]);
// Setup validates the complete immutable payload once. Launch binds the
// manifest and essential executable/Skill identities without scanning gigabytes
// for every developer subprocess or changing ordinary Task environments.
for (const file of component.manifest.files) {
  if (
    typeof file.path !== "string" ||
    file.path.includes("\\") ||
    file.path
      .split("/")
      .some((part) => !part || part === "." || part === "..") ||
    path.isAbsolute(file.path)
  )
    throw new Error("Unsafe Office component manifest path");
  const filename = path.join(component.root, file.path);
  const status = lstatSync(filename);
  if (!status.isFile() || status.isSymbolicLink() || status.size !== file.bytes)
    throw new Error(`Office component file identity mismatch: ${file.path}`);
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(filename)) digest.update(chunk);
  if (digest.digest("hex") !== file.sha256)
    throw new Error(`Office component file digest mismatch: ${file.path}`);
}
const result = spawnSync(component.entry, ["selftest"], {
  cwd: root,
  encoding: "utf8",
  timeout: 300_000,
  windowsHide: true,
});
if (
  result.error ||
  result.status !== 0 ||
  JSON.parse(result.stdout).status !== "success"
)
  throw new Error(
    "Office component self-test failed; local selection was not changed",
  );
const filename = officeEnvironmentPath(root);
mkdirSync(path.dirname(filename), { recursive: true });
const temporary = `${filename}.${randomUUID()}.tmp`;
try {
  writeFileSync(
    temporary,
    JSON.stringify(
      {
        schema: 2,
        componentRoot: component.root,
        manifestSha256: component.manifestSha256,
      },
      null,
      2,
    ) + "\n",
  );
  renameSync(temporary, filename);
} finally {
  if (existsSync(temporary)) unlinkSync(temporary);
}

console.log(`Local Office component selected: ${component.root}`);
