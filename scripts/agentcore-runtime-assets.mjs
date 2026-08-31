import { createHash } from "node:crypto";
import { chmod, copyFile, lstat, mkdir, readFile } from "node:fs/promises";
import path from "node:path";

async function verifyFile(filePath, expected) {
  const metadata = await lstat(filePath);
  if (
    !metadata.isFile() ||
    metadata.isSymbolicLink() ||
    metadata.size > 128 * 1024 * 1024
  )
    throw new Error(
      `AgentCore runtime asset is not a bounded regular file: ${filePath}`,
    );
  const digest = createHash("sha256")
    .update(await readFile(filePath))
    .digest("hex");
  if (digest !== expected)
    throw new Error(`AgentCore runtime asset checksum mismatch: ${filePath}`);
}

// The caller supplies the result of the strict bundle verifier. Package assets
// come only from that bundle, never from PATH or the producer's source tree.
export async function verifyAgentCoreRuntimeAssets(
  bundle,
  executableDirectory,
) {
  for (const file of bundle.runtimeFiles)
    await verifyFile(
      path.join(executableDirectory, path.basename(file.path)),
      file.sha256,
    );
}

export async function stageAgentCoreRuntimeAssets(bundle, executableDirectory) {
  await mkdir(executableDirectory, { recursive: true });
  for (const file of bundle.runtimeFiles) {
    const source = path.join(bundle.root, file.path);
    await verifyFile(source, file.sha256);
    const destination = path.join(
      executableDirectory,
      path.basename(file.path),
    );
    await copyFile(source, destination);
    if (file.path === "bin/rg") await chmod(destination, 0o755);
  }
  await verifyAgentCoreRuntimeAssets(bundle, executableDirectory);
}
