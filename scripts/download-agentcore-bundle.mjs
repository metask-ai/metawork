import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  defaultAgentCoreTargetId,
  loadLockedAgentCoreManifest,
  readAgentCoreBundleTargetId,
} from "./agentcore-bundle.mjs";
import { runChild } from "./run-child-process.mjs";
import { stageAgentCoreBundle } from "./stage-agentcore-bundle.mjs";

const transientNetworkErrors = new Set([
  "EAI_AGAIN",
  "ECONNRESET",
  "ETIMEDOUT",
  "UND_ERR_BODY_TIMEOUT",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_HEADERS_TIMEOUT",
  "UND_ERR_SOCKET",
]);

export async function downloadAgentCoreArchive(
  lock,
  targetId,
  { fetchResponse = fetch, cacheDir } = {},
) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(lock.version))
    throw new Error("AgentCore lock must specify a stable release version");

  const releaseUrl = new URL(
    `https://downloads.metask-ai.com/agentcore/v${lock.version}/`,
  );
  let canRetry = true;
  async function download(url) {
    for (;;) {
      let httpStatus;
      try {
        const response = await fetchResponse(url, {
          redirect: "error",
          signal: AbortSignal.timeout(120_000),
        });
        if (!response.ok) {
          httpStatus = response.status;
          await response.body?.cancel().catch(() => {});
          throw new Error(`HTTP ${httpStatus}`);
        }
        return Buffer.from(await response.arrayBuffer());
      } catch (error) {
        if (
          !canRetry ||
          (httpStatus !== 429 &&
            !(httpStatus >= 500 && httpStatus < 600) &&
            error.name !== "TimeoutError" &&
            !transientNetworkErrors.has(error.cause?.code ?? error.code))
        )
          throw new Error(
            `AgentCore download failed: ${url}: ${error.message}`,
            {
              cause: error,
            },
          );
        canRetry = false;
        console.warn(`Retrying AgentCore download: ${url}: ${error.message}`);
      }
    }
  }

  const cacheExists =
    cacheDir &&
    (await stat(cacheDir).catch((error) => {
      if (error.code === "ENOENT") return null;
      throw error;
    }));
  const manifestBytes = cacheExists
    ? await readFile(path.join(cacheDir, "manifest.json"))
    : await download(new URL("manifest.json", releaseUrl));
  const release = JSON.parse(manifestBytes.toString("utf8"));
  if (
    release.schema_version !== 1 ||
    release.version !== lock.version ||
    release.source_commit !== lock.source.commit ||
    release.binary_abi?.version !== lock.contract.binary_abi_version ||
    release.binary_abi?.revision !== lock.contract.binary_abi_revision
  )
    throw new Error(
      "AgentCore release manifest does not match the repository lock",
    );

  const targets = Object.entries(release.targets ?? {}).filter(
    ([, artifact]) => artifact?.custom?.target === targetId,
  );
  if (targets.length !== 1)
    throw new Error(
      `AgentCore release must contain exactly one ${targetId} bundle`,
    );
  const [[archivePath, artifact]] = targets;
  const digest = artifact.hashes?.sha256;
  if (
    !/^[\w.-]+(?:\/[\w.-]+)*$/.test(archivePath) ||
    archivePath.split("/").some((part) => part === "." || part === "..") ||
    !Number.isSafeInteger(artifact.length) ||
    artifact.length <= 0 ||
    !/^[a-f0-9]{64}$/.test(digest)
  )
    throw new Error(`Invalid AgentCore archive metadata for ${targetId}`);

  const archiveUrl = new URL(archivePath, releaseUrl);
  const bytes = cacheExists
    ? await readFile(path.join(cacheDir, "bundle.archive"))
    : await download(archiveUrl);
  if (bytes.length !== artifact.length)
    throw new Error(`AgentCore archive length mismatch: ${archiveUrl}`);
  if (createHash("sha256").update(bytes).digest("hex") !== digest)
    throw new Error(`AgentCore archive SHA-256 mismatch: ${archiveUrl}`);
  if (cacheExists) {
    console.log(`Verified cached AgentCore release for ${targetId}`);
  } else if (cacheDir) {
    const parent = path.dirname(cacheDir);
    await mkdir(parent, { recursive: true });
    const temporary = await mkdtemp(
      path.join(parent, `${path.basename(cacheDir)}.tmp-`),
    );
    try {
      await writeFile(path.join(temporary, "manifest.json"), manifestBytes);
      await writeFile(path.join(temporary, "bundle.archive"), bytes);
      await rename(temporary, cacheDir);
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  }
  return bytes;
}

const isMain =
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
  const [targetId] = process.argv.slice(2);
  if (process.argv.length !== 3)
    throw new Error(
      "usage: node scripts/download-agentcore-bundle.mjs <target-id>",
    );
  const hostTargetId = defaultAgentCoreTargetId();
  if (targetId !== hostTargetId)
    throw new Error(
      `AgentCore target ${targetId} does not match ${hostTargetId}`,
    );

  const { manifest: lock } = await loadLockedAgentCoreManifest(
    repositoryRoot,
    targetId,
  );
  const bytes = await downloadAgentCoreArchive(lock, targetId, {
    cacheDir: process.env.METAWORK_AGENTCORE_DOWNLOAD_CACHE,
  });

  const work = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-"));
  try {
    const archive = path.join(work, "bundle.archive");
    const extracted = path.join(work, "extracted");
    await writeFile(archive, bytes);
    await mkdir(extracted);
    const tar =
      process.platform === "win32"
        ? path.join(process.env.SystemRoot, "System32", "tar.exe")
        : "/usr/bin/tar";
    await runChild(tar, ["-xf", archive, "-C", extracted], {
      cwd: work,
      label: "Extract AgentCore archive",
    });
    const entries = await readdir(extracted, { withFileTypes: true });
    if (entries.length !== 1 || !entries[0].isDirectory())
      throw new Error(
        "AgentCore archive must contain a single bundle directory",
      );
    const source = path.join(extracted, entries[0].name);
    if ((await readAgentCoreBundleTargetId(source)) !== targetId)
      throw new Error(
        `AgentCore archive does not contain the ${targetId} bundle`,
      );
    const staged = await stageAgentCoreBundle({ repositoryRoot, source });
    console.log(
      `Staged AgentCore ${lock.version} (${lock.source.commit}) at ${staged.target}`,
    );
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}
