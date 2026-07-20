import {
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
} from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import process from "node:process";
import { validateAgentCoreBundle } from "./agentcore-bundle.mjs";

const lockRelativePath = path.join(
  "spikes",
  "agentcore-contract",
  "bundle.lock.json",
);

async function exists(filePath) {
  try {
    await lstat(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function loadLock(repositoryRoot) {
  const bytes = await readFile(
    path.join(repositoryRoot, lockRelativePath),
    "utf8",
  );
  return { bytes, manifest: JSON.parse(bytes) };
}

async function recoverStagingResidues(storageRoot, target) {
  const entries = await readdir(storageRoot, { withFileTypes: true });
  const stagingPaths = entries
    .filter((entry) => entry.name.startsWith(".bundle-staging-"))
    .map((entry) => path.join(storageRoot, entry.name));
  const backupPaths = entries
    .filter((entry) => entry.name.startsWith(".bundle-backup-"))
    .map((entry) => path.join(storageRoot, entry.name));
  await Promise.all(
    stagingPaths.map((entry) => rm(entry, { recursive: true, force: true })),
  );

  if (await exists(target)) {
    return backupPaths;
  }
  if (backupPaths.length > 1)
    throw new Error(
      "multiple AgentCore backup residues exist without a canonical bundle",
    );
  if (backupPaths.length === 1) {
    await rename(backupPaths[0], target);
    return [];
  }
  return backupPaths;
}

export async function stageAgentCoreBundle({
  repositoryRoot,
  source,
  validationOptions = {},
}) {
  if (!path.isAbsolute(source))
    throw new Error("AgentCore candidate path must be absolute");
  const lock = await loadLock(repositoryRoot);
  const validated = await validateAgentCoreBundle(source, {
    ...validationOptions,
    expectedManifest: lock.manifest,
    expectedManifestBytes: lock.bytes,
  });

  const storageRoot = path.join(repositoryRoot, ".agentcore");
  const target = path.join(storageRoot, "bundle");
  await mkdir(storageRoot, { recursive: true });
  const staleBackups = await recoverStagingResidues(storageRoot, target);

  const staging = await mkdtemp(path.join(storageRoot, ".bundle-staging-"));
  const backup = path.join(
    storageRoot,
    `.bundle-backup-${process.pid}-${Date.now()}`,
  );
  let movedTarget = false;

  try {
    for (const relativePath of ["manifest.json", ...validated.payloadFiles]) {
      const destination = path.join(staging, relativePath);
      await mkdir(path.dirname(destination), { recursive: true });
      await copyFile(path.join(validated.root, relativePath), destination);
    }
    await validateAgentCoreBundle(staging, {
      ...validationOptions,
      expectedManifest: lock.manifest,
      expectedManifestBytes: lock.bytes,
    });

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
    await Promise.all(
      staleBackups.map((entry) => rm(entry, { recursive: true, force: true })),
    );
  } finally {
    await rm(staging, { recursive: true, force: true });
  }

  return { target, manifest: lock.manifest };
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const [source] = process.argv.slice(2);
  if (!source || process.argv.length !== 3 || !path.isAbsolute(source)) {
    throw new Error(
      "usage: npm run agentcore:stage -- /absolute/path/to/validated/bundle",
    );
  }
  const repositoryRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
  );
  const result = await stageAgentCoreBundle({ repositoryRoot, source });
  console.log(
    `staged ${result.manifest.version} (${result.manifest.source.commit}) at ${result.target}`,
  );
}
