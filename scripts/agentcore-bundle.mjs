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

function requireExactKeys(value, keys, field) {
  requireValue(
    value !== null && typeof value === "object" && !Array.isArray(value),
    `${field} must be an object`,
  );
  requireValue(
    isDeepStrictEqual(Object.keys(value).sort(), [...keys].sort()),
    `${field} fields do not match the AgentCore manifest contract`,
  );
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
  requireExactKeys(
    manifest,
    [
      "schema_version",
      "name",
      "version",
      "source",
      "toolchain",
      "build",
      "contract",
      "files",
    ],
    "manifest",
  );
  requireExactKeys(
    manifest.source,
    ["commit", "dirty", "dirty_source_sha256"],
    "source",
  );
  requireExactKeys(manifest.toolchain, ["zig_version"], "toolchain");
  requireExactKeys(
    manifest.build,
    ["resolved_target", "architecture", "os", "abi", "optimize", "strip"],
    "build",
  );
  requireExactKeys(
    manifest.contract,
    ["binary_abi_version", "required_system_link_inputs", "ui_request_mode"],
    "contract",
  );
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
  const version = requireString(manifest.version, "version");
  const commit = requireString(manifest.source.commit, "source.commit");
  requireValue(
    /^[0-9a-f]{40}$/.test(commit),
    "source.commit must be a full lowercase SHA",
  );
  requireValue(
    typeof manifest.source?.dirty === "boolean",
    "source.dirty must be boolean",
  );
  const dirtySourceDigest = manifest.source.dirty_source_sha256;
  if (manifest.source.dirty) {
    requireValue(
      /^[0-9a-f]{64}$/.test(dirtySourceDigest),
      "dirty bundle must include dirty_source_sha256",
    );
  } else {
    requireValue(
      dirtySourceDigest === "",
      "clean bundle must use an empty dirty_source_sha256",
    );
  }
  const expectedVersion = `0.0.0-dev+${commit.slice(0, 12)}${
    manifest.source.dirty ? `-dirty.${dirtySourceDigest.slice(0, 12)}` : ""
  }`;
  requireValue(
    version === expectedVersion,
    "AgentCore version does not match source identity",
  );

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
    requireString(
      manifest.build.resolved_target,
      "build.resolved_target",
    ).match(
      new RegExp(
        `^${architecture}-macos\\.(\\d+\\.\\d+(?:\\.\\d+)?)(?:\\.\\.\\.[^-]+)?-none$`,
      ),
    )?.[1],
    "build.resolved_target macOS deployment target",
  );
  requireValue(
    manifest.build.abi === "none",
    "unsupported AgentCore target ABI",
  );
  requireValue(
    manifest.build?.optimize === "ReleaseSafe",
    "unsupported AgentCore optimize mode",
  );
  requireValue(
    manifest.build?.strip === true,
    "AgentCore bundle must be stripped",
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

  requireValue(
    Array.isArray(manifest.files),
    "AgentCore manifest files must be an array",
  );
  const declaredFiles = manifest.files.map((file, index) => {
    requireExactKeys(file, ["path", "sha256"], `files[${index}]`);
    const relativePath = requireString(file.path, `files[${index}].path`);
    requireValue(
      /^[0-9a-f]{64}$/.test(file.sha256),
      `invalid checksum for ${relativePath}`,
    );
    return relativePath;
  });
  requireValue(
    isDeepStrictEqual([...declaredFiles].sort(), [...bundleFiles].sort()),
    "AgentCore manifest file set is incomplete or contains unknown files",
  );
  for (const relativePath of bundleFiles) {
    const expected = manifest.files.find(
      (file) => file.path === relativePath,
    ).sha256;
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
