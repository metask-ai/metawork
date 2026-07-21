import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import process from "node:process";
import {
  loadLockedAgentCoreManifest,
  readAgentCoreBundleTargetId,
  validateAgentCoreBundle,
} from "./agentcore-bundle.mjs";

export async function verifyStagedAgentCoreBundle(
  repositoryRoot,
  validationOptions = {},
) {
  const stagedRoot = path.join(repositoryRoot, ".agentcore", "bundle");
  try {
    const targetId = await readAgentCoreBundleTargetId(stagedRoot);
    const lock = await loadLockedAgentCoreManifest(repositoryRoot, targetId);
    return await validateAgentCoreBundle(stagedRoot, {
      ...validationOptions,
      expectedManifest: lock.manifest,
      expectedManifestBytes: lock.bytes,
    });
  } catch (error) {
    if (error?.code === "ENOENT")
      throw new Error(
        "staged AgentCore bundle is missing; run npm run agentcore:stage first",
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
