import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { bundleFiles, validateAgentCoreBundle } from "./agentcore-bundle.mjs";

const [source] = process.argv.slice(2);
if (!source || process.argv.length !== 3 || !path.isAbsolute(source)) {
  throw new Error(
    "usage: npm run agentcore:stage -- /absolute/path/to/validated/bundle",
  );
}

const root = process.cwd();
const lock = JSON.parse(
  await readFile(
    path.join(root, "spikes/agentcore-contract/bundle.lock.json"),
    "utf8",
  ),
);
const validated = await validateAgentCoreBundle(source, {
  expectedManifest: lock,
});

const storageRoot = path.join(root, ".agentcore");
const target = path.join(storageRoot, "bundle");
await mkdir(storageRoot, { recursive: true });
const staging = await mkdtemp(path.join(storageRoot, ".bundle-staging-"));
const backup = path.join(
  storageRoot,
  `.bundle-backup-${process.pid}-${Date.now()}`,
);
let movedTarget = false;

try {
  for (const relativePath of ["manifest.json", ...bundleFiles]) {
    const destination = path.join(staging, relativePath);
    await mkdir(path.dirname(destination), { recursive: true });
    await copyFile(path.join(validated.root, relativePath), destination);
  }
  await validateAgentCoreBundle(staging, { expectedManifest: lock });

  try {
    await rename(target, backup);
    movedTarget = true;
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  try {
    await rename(staging, target);
  } catch (error) {
    if (movedTarget) await rename(backup, target);
    throw error;
  }
  if (movedTarget) await rm(backup, { recursive: true, force: true });
} finally {
  await rm(staging, { recursive: true, force: true });
}

console.log(
  `staged ${lock.version} (${lock.source.cc_zig_commit}) at ${target}`,
);
