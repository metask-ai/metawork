import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import process from "node:process";
import {
  defaultAgentCoreTargetId,
  loadLockedAgentCoreManifest,
  readAgentCoreBundleTargetId,
  stagedAgentCoreBundleRoot,
  validateAgentCoreBundle,
} from "./agentcore-bundle.mjs";

export async function verifyStagedAgentCoreBundle(
  repositoryRoot,
  { targetId = defaultAgentCoreTargetId(), validationOptions = {} } = {},
) {
  const stagedRoot = stagedAgentCoreBundleRoot(repositoryRoot, targetId);
  try {
    const actualTargetId = await readAgentCoreBundleTargetId(stagedRoot);
    if (actualTargetId !== targetId)
      throw new Error(
        `staged AgentCore target is ${actualTargetId}, expected ${targetId}`,
      );
    const lock = await loadLockedAgentCoreManifest(
      repositoryRoot,
      actualTargetId,
    );
    return await validateAgentCoreBundle(stagedRoot, {
      ...validationOptions,
      expectedManifest: lock.manifest,
      expectedManifestBytes: lock.bytes,
    });
  } catch (error) {
    if (error?.code === "ENOENT")
      throw new Error(
        `staged AgentCore bundle ${targetId} is missing; run node scripts/stage-agentcore-bundle.mjs <absolute-bundle-path> first`,
        { cause: error },
      );
    throw error;
  }
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const repositoryRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
  );
  const result = await verifyStagedAgentCoreBundle(repositoryRoot);
  console.log(
    `verified staged AgentCore ${result.manifest.version} ABI ${result.manifest.contract.binary_abi_version} revision ${result.manifest.contract.binary_abi_revision}`,
  );
}
