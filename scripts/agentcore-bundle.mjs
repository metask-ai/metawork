import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { lstat, readFile, readdir, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { isDeepStrictEqual, promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const bundleFiles = [
  "lib/libmetacodes_agentcore.a",
  "include/metacodes_agentcore.h",
  "sdk/metacodes_agentcore.zig",
  "sdk/metacodes_agentcore_protocol.zig",
  "sdk/metacodes_agentcore_types.zig",
];

const bundleDirectories = ["include/", "lib/", "sdk/"];
const bundleEntries = [
  ...bundleDirectories,
  "manifest.json",
  ...bundleFiles,
].sort();

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function requireString(value, field) {
  requireValue(
    typeof value === "string" && value.length > 0,
    `${field} must be a non-empty string`,
  );
  return value;
}

function expectedBundlePlatform(platform) {
  if (platform === "darwin") return "macos";
  throw new Error(`unsupported AgentCore host platform: ${platform}`);
}

function expectedBundleArchitecture(architecture) {
  if (architecture === "arm64") return "aarch64";
  throw new Error(`unsupported AgentCore host architecture: ${architecture}`);
}

async function sha256(filePath) {
  requireValue(
    (await stat(filePath)).size <= 128 * 1024 * 1024,
    `AgentCore artifact exceeds 128 MiB: ${filePath}`,
  );
  const bytes = await readFile(filePath);
  return createHash("sha256").update(bytes).digest("hex");
}

async function listBundleEntries(root, relativeDirectory = "") {
  const entries = await readdir(path.join(root, relativeDirectory), {
    withFileTypes: true,
  });
  const result = [];
  for (const entry of entries) {
    const relativePath = path.posix.join(relativeDirectory, entry.name);
    const metadata = await lstat(path.join(root, relativePath));
    requireValue(
      !metadata.isSymbolicLink(),
      `AgentCore bundle contains a symbolic link: ${relativePath}`,
    );
    if (metadata.isDirectory()) {
      result.push(`${relativePath}/`);
      result.push(...(await listBundleEntries(root, relativePath)));
    } else {
      requireValue(
        metadata.isFile(),
        `AgentCore bundle contains a non-file entry: ${relativePath}`,
      );
      result.push(relativePath);
    }
  }
  return result;
}

export async function validateAgentCoreBundle(bundleRoot, options = {}) {
  requireValue(
    path.isAbsolute(bundleRoot),
    "AGENTCORE_BUNDLE_ROOT must be absolute",
  );
  const root = await realpath(bundleRoot);
  const actualEntries = (await listBundleEntries(root)).sort();
  requireValue(
    isDeepStrictEqual(actualEntries, bundleEntries),
    "AgentCore bundle filesystem contains missing or unknown entries",
  );
  const manifestPath = path.join(root, "manifest.json");
  requireValue(
    (await stat(manifestPath)).size <= 1024 * 1024,
    "AgentCore manifest exceeds 1 MiB",
  );

  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`invalid AgentCore manifest: ${error.message}`, {
      cause: error,
    });
  }
  if (options.expectedManifest) {
    requireValue(
      isDeepStrictEqual(manifest, options.expectedManifest),
      "AgentCore manifest does not match the repository lock",
    );
  }

  requireValue(
    manifest.schema_version === 1,
    "unsupported AgentCore manifest schema",
  );
  requireValue(
    manifest.name === "metacodes-agentcore",
    "unexpected AgentCore bundle name",
  );
  requireString(manifest.version, "version");
  const commit = requireString(
    manifest.source?.cc_zig_commit,
    "source.cc_zig_commit",
  );
  requireValue(
    /^[0-9a-f]{40}$/.test(commit),
    "source.cc_zig_commit must be a full lowercase SHA",
  );
  requireValue(
    typeof manifest.source?.dirty === "boolean",
    "source.dirty must be boolean",
  );
  if (manifest.source.dirty) {
    requireValue(
      /^[0-9a-f]{64}$/.test(manifest.source.dirty_source_sha256 ?? ""),
      "dirty bundle must include dirty_source_sha256",
    );
  }

  const zigVersion = requireString(
    manifest.toolchain?.zig_version,
    "toolchain.zig_version",
  );
  const platform = expectedBundlePlatform(options.platform ?? process.platform);
  const architecture = expectedBundleArchitecture(
    options.architecture ?? process.arch,
  );
  requireValue(
    manifest.build?.os === platform,
    `bundle OS ${manifest.build?.os} does not match ${platform}`,
  );
  requireValue(
    manifest.build?.architecture === architecture,
    `bundle architecture ${manifest.build?.architecture} does not match ${architecture}`,
  );
  const deploymentTarget = requireString(
    manifest.build?.macos_deployment_target,
    "build.macos_deployment_target",
  );
  requireValue(
    requireString(
      manifest.build?.resolved_target,
      "build.resolved_target",
    ).startsWith(`${architecture}-macos.${deploymentTarget}`),
    "resolved target and deployment target disagree",
  );
  requireValue(
    manifest.build?.optimize === "ReleaseSafe",
    "unsupported AgentCore optimize mode",
  );
  requireValue(
    manifest.contract?.binary_abi_version === 1,
    "unsupported AgentCore binary ABI",
  );
  requireValue(
    manifest.contract?.ui_request_mode === "synchronous",
    "unsupported UI request mode",
  );
  requireValue(
    JSON.stringify(manifest.contract?.required_system_link_inputs) ===
      JSON.stringify(["libc"]),
    "unsupported AgentCore system link inputs",
  );

  const declaredFiles = Object.keys(manifest.files ?? {}).sort();
  requireValue(
    JSON.stringify(declaredFiles) === JSON.stringify([...bundleFiles].sort()),
    "AgentCore manifest file set is incomplete or contains unknown files",
  );
  for (const relativePath of bundleFiles) {
    const expected = manifest.files[relativePath]?.sha256;
    requireValue(
      /^[0-9a-f]{64}$/.test(expected ?? ""),
      `invalid checksum for ${relativePath}`,
    );
    const actual = await sha256(path.join(root, relativePath));
    requireValue(
      actual === expected,
      `AgentCore checksum mismatch: ${relativePath}`,
    );
  }

  const actualZigVersion =
    options.zigVersion ??
    (
      await execFileAsync("zig", ["version"], { encoding: "utf8" })
    ).stdout.trim();
  requireValue(
    actualZigVersion === zigVersion,
    `bundle Zig ${zigVersion} does not match host Zig ${actualZigVersion}`,
  );

  const symbols =
    options.symbols ??
    (
      await execFileAsync(
        "nm",
        ["-gU", path.join(root, "lib/libmetacodes_agentcore.a")],
        {
          encoding: "utf8",
          maxBuffer: 16 * 1024 * 1024,
        },
      )
    ).stdout;
  const discoveryMatches =
    symbols.match(/\b_?metacodes_agentcore_get_api\b/g) ?? [];
  requireValue(
    discoveryMatches.length === 1,
    "AgentCore bundle must expose exactly one discovery symbol",
  );

  return {
    root,
    manifest,
    target: `${architecture}-macos.${deploymentTarget}`,
  };
}
