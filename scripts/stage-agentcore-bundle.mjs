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
import {
  defaultAgentCoreTargetId,
  loadLockedAgentCoreManifest,
  policyForTargetId,
  readAgentCoreBundleTargetId,
  stagedAgentCoreBundleRoot,
  validateAgentCoreBundle,
} from "./agentcore-bundle.mjs";
import { runChild } from "./run-child-process.mjs";

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

async function recoverStagingResidues(
  storageRoot,
  target,
  residueName,
  fileOperations,
) {
  const entries = await readdir(storageRoot, { withFileTypes: true });
  const stagingPaths = entries
    .filter((entry) => entry.name.startsWith(`.${residueName}-staging-`))
    .map((entry) => path.join(storageRoot, entry.name));
  const backupPaths = entries
    .filter((entry) => entry.name.startsWith(`.${residueName}-backup-`))
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

async function installPayload({
  source,
  storageRoot,
  targetName,
  files,
  validate,
  fileOperations,
}) {
  await mkdir(storageRoot, { recursive: true });
  const target = path.join(storageRoot, targetName);
  const staleBackups = await recoverStagingResidues(
    storageRoot,
    target,
    targetName,
    fileOperations,
  );

  const staging = await mkdtemp(
    path.join(storageRoot, `.${targetName}-staging-`),
  );
  const backup = path.join(
    storageRoot,
    `.${targetName}-backup-${process.pid}-${Date.now()}`,
  );
  let movedTarget = false;
  let operationError;

  try {
    for (const file of files) {
      const destination = path.join(staging, file.destination);
      await mkdir(path.dirname(destination), { recursive: true });
      await fileOperations.copyFile(path.join(source, file.path), destination);
    }
    await validate(staging);

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
  return target;
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
  const targetId = lock.manifest.target.id;
  const target = await installPayload({
    source: validated.root,
    storageRoot: path.join(repositoryRoot, ".agentcore", "bundles"),
    targetName: targetId,
    files: ["manifest.json", ...validated.payloadFiles].map((relativePath) => ({
      destination: relativePath,
      path: relativePath,
    })),
    validate: (root) =>
      validateAgentCoreBundle(root, {
        ...validationOptions,
        expectedManifest: lock.manifest,
        expectedManifestBytes: lock.bytes,
      }),
    fileOperations,
  });

  if (target !== stagedAgentCoreBundleRoot(repositoryRoot, targetId))
    throw new Error("AgentCore target store path invariant failed");
  return { target, manifest: lock.manifest };
}

// `npm ci` installs only this host's platform package, so a cross-compiled
// target's is not in node_modules yet. Installing it by name puts it beside
// the host's and changes nothing else there: --force lets a package for
// another os/cpu in, and --no-save leaves package.json and the lockfile alone.
async function installWithNpm(repositoryRoot, spec) {
  const npmArguments = ["install", "--no-save", "--force", spec];
  console.log(`npm ${npmArguments.join(" ")}`);
  // npm is a .cmd shim on Windows, which cannot be started without cmd.exe.
  const [command, arguments_] =
    process.platform === "win32"
      ? [
          path.join(process.env.SystemRoot, "System32", "cmd.exe"),
          ["/d", "/s", "/c", "npm", ...npmArguments],
        ]
      : ["npm", npmArguments];
  await runChild(command, arguments_, {
    cwd: repositoryRoot,
    label: `Install ${spec}`,
  });
}

// node_modules is the one place a bundle comes from. npm holds a by-name
// install to no lockfile integrity, so what makes the content the locked one
// is the same thing as for any candidate: the target lock checked on staging.
export async function stageAgentCorePackage({
  repositoryRoot,
  targetId,
  install = installWithNpm,
  validationOptions = {},
}) {
  const name = policyForTargetId(targetId).npmPackage;
  const source = path.join(repositoryRoot, "node_modules", name);
  if (!(await exists(source))) {
    const version = JSON.parse(
      await readFile(path.join(repositoryRoot, "package.json"), "utf8"),
    ).devDependencies?.["@zogien/agent-sdk"];
    // The version goes on a command line, so only the exact pinned form does.
    if (
      typeof version !== "string" ||
      !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-fork\.[1-9]\d*$/.test(version)
    )
      throw new Error(
        "package.json must pin @zogien/agent-sdk to an exact fork release",
      );
    await install(repositoryRoot, `${name}@${version}`);
  }
  return stageAgentCoreBundle({
    repositoryRoot,
    source,
    validationOptions: { ...validationOptions, npmPackage: true },
  });
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const arguments_ = process.argv.slice(2);
  if (arguments_.length > 1) {
    throw new Error(
      "usage: node scripts/stage-agentcore-bundle.mjs [target-id | /absolute/path/to/validated/bundle]",
    );
  }
  const repositoryRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
  );
  // No argument means this machine's own target; a cross-compiled build names
  // the target it is building for.
  const [argument = defaultAgentCoreTargetId()] = arguments_;
  const result = path.isAbsolute(argument)
    ? await stageAgentCoreBundle({ repositoryRoot, source: argument })
    : await stageAgentCorePackage({ repositoryRoot, targetId: argument });
  console.log(
    `staged ${result.manifest.version} (${result.manifest.source.commit}) at ${result.target}`,
  );
}
