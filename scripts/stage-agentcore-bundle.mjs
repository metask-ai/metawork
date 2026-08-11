import {
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  rename,
  rm,
} from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import process from "node:process";
import {
  loadLockedAgentCoreManifest,
  readAgentCoreBundleTargetId,
  validateAgentCoreBundle,
} from "./agentcore-bundle.mjs";

async function exists(filePath) {
  try {
    await lstat(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function loadLock(repositoryRoot, source) {
  const targetId = await readAgentCoreBundleTargetId(source);
  return loadLockedAgentCoreManifest(repositoryRoot, targetId);
}

const defaultFileOperations = { copyFile, rename, rm };

async function recoverStagingResidues(storageRoot, target, fileOperations) {
  const entries = await readdir(storageRoot, { withFileTypes: true });
  const stagingPaths = entries
    .filter((entry) => entry.name.startsWith(".bundle-staging-"))
    .map((entry) => path.join(storageRoot, entry.name));
  const backupPaths = entries
    .filter((entry) => entry.name.startsWith(".bundle-backup-"))
    .map((entry) => path.join(storageRoot, entry.name));
  await Promise.all(
    stagingPaths.map((entry) =>
      fileOperations.rm(entry, { recursive: true, force: true }),
    ),
  );

  if (await exists(target)) {
    return backupPaths;
  }
  if (backupPaths.length > 1)
    throw new Error(
      "multiple AgentCore backup residues exist without a canonical bundle",
    );
  if (backupPaths.length === 1) {
    await fileOperations.rename(backupPaths[0], target);
    return [];
  }
  return backupPaths;
}

export async function stageAgentCoreBundle({
  repositoryRoot,
  source,
  validationOptions = {},
  fileOperations = defaultFileOperations,
}) {
  if (!path.isAbsolute(source))
    throw new Error("AgentCore candidate path must be absolute");
  const lock = await loadLock(repositoryRoot, source);
  const validated = await validateAgentCoreBundle(source, {
    ...validationOptions,
    expectedManifest: lock.manifest,
    expectedManifestBytes: lock.bytes,
  });

  const storageRoot = path.join(repositoryRoot, ".agentcore");
  const target = path.join(storageRoot, "bundle");
  await mkdir(storageRoot, { recursive: true });
  const staleBackups = await recoverStagingResidues(
    storageRoot,
    target,
    fileOperations,
  );

  const staging = await mkdtemp(path.join(storageRoot, ".bundle-staging-"));
  const backup = path.join(
    storageRoot,
    `.bundle-backup-${process.pid}-${Date.now()}`,
  );
  let movedTarget = false;
  let operationError;

  try {
    for (const relativePath of ["manifest.json", ...validated.payloadFiles]) {
      const destination = path.join(staging, relativePath);
      await mkdir(path.dirname(destination), { recursive: true });
      await fileOperations.copyFile(
        path.join(validated.root, relativePath),
        destination,
      );
    }
    await validateAgentCoreBundle(staging, {
      ...validationOptions,
      expectedManifest: lock.manifest,
      expectedManifestBytes: lock.bytes,
    });

    try {
      await fileOperations.rename(target, backup);
      movedTarget = true;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    try {
      await fileOperations.rename(staging, target);
    } catch (error) {
      if (movedTarget) {
        try {
          await fileOperations.rename(backup, target);
        } catch (restoreError) {
          throw new AggregateError(
            [error, restoreError],
            "AgentCore install and canonical restore both failed",
          );
        }
      }
      throw error;
    }
    try {
      if (movedTarget)
        await fileOperations.rm(backup, { recursive: true, force: true });
      await Promise.all(
        staleBackups.map((entry) =>
          fileOperations.rm(entry, { recursive: true, force: true }),
        ),
      );
    } catch (error) {
      throw new Error(
        "AgentCore bundle was installed but backup cleanup failed",
        { cause: error },
      );
    }
  } catch (error) {
    operationError = error;
  }
  try {
    await fileOperations.rm(staging, { recursive: true, force: true });
  } catch (cleanupError) {
    if (operationError)
      throw new AggregateError(
        [operationError, cleanupError],
        "AgentCore staging failed and temporary cleanup also failed",
      );
    throw cleanupError;
  }
  if (operationError) throw operationError;

  return { target, manifest: lock.manifest };
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const [source] = process.argv.slice(2);
  if (!source || process.argv.length !== 3 || !path.isAbsolute(source)) {
    throw new Error(
      "usage: node scripts/stage-agentcore-bundle.mjs /absolute/path/to/validated/bundle",
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
