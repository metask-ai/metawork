// Build the small, self-owned input for public-source installation. This does
// not publish a release or make a development component client-installable.
import {
  createReadStream,
  mkdirSync,
  mkdtempSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readOfficeComponent } from "./office-environment.mjs";
import {
  officeComponentSources,
  officeDependencyRecipe,
  officeDownloadLayout,
  queryOfficeAuthoring,
} from "./office-component-sources.mjs";
import { runChild } from "./run-child-process.mjs";

if (process.platform !== "win32" || process.argv.length !== 5)
  throw new Error(
    "Usage: build-office-install-seed.mjs <prepared-component> <canonical-download-cache> <new-absolute-seed.tar.gz>",
  );
const root = fileURLToPath(new URL("..", import.meta.url));
const component = readOfficeComponent(path.resolve(process.argv[2]));
const downloads = path.resolve(process.argv[3]);
const output = process.argv[4];
if (!path.isAbsolute(output) || !output.endsWith(".tar.gz"))
  throw new Error("New absolute seed output is required");
const authoring = queryOfficeAuthoring(root);
const sources = officeComponentSources(root).sources;
const files = [];
for (const entry of officeDownloadLayout(root, authoring)) {
  const hash = createHash(entry.algorithm);
  let bytes = 0;
  for await (const chunk of createReadStream(
    path.join(downloads, entry.path),
  )) {
    hash.update(chunk);
    bytes += chunk.length;
    if (bytes > (entry.bytes ?? 256 * 1024 * 1024))
      throw new Error("Public source exceeds seed input budget");
  }
  if (
    hash.digest("hex") !== entry.digest ||
    (entry.bytes !== null && bytes !== entry.bytes)
  )
    throw new Error("Public source differs from its fixed identity");
  files.push({ ...entry, bytes });
}
const cache = path.join(root, ".zig-cache/office-install-seed");
mkdirSync(cache, { recursive: true });
const directory = mkdtempSync(path.join(cache, "run-"));
const planPath = path.join(directory, "plan.json");
writeFileSync(
  planPath,
  JSON.stringify(
    {
      schema: 1,
      target: sources.target,
      manifestSha256: component.manifestSha256,
      sources,
      recipe: officeDependencyRecipe(root, authoring),
      downloads: files,
    },
    null,
    2,
  ) + "\n",
);
await runChild(
  component.entry,
  [
    "python",
    path.join(root, "scripts/prepare-office-install-seed.py"),
    component.root,
    planPath,
    output,
  ],
  { cwd: root, label: "Office self-owned installation seed", timeoutMs: null },
);
