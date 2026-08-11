import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { lstat, readFile, readdir, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { isDeepStrictEqual, promisify } from "node:util";

const execFileAsync = promisify(execFile);
const maxManifestBytes = 1024 * 1024;
const maxPayloadBytes = 128 * 1024 * 1024;
const maxPayloadFiles = 256;
const supportedAbiVersion = 1;
const supportedAbiRevision = 7;
const supportedAbiTableSize = 216;
const supportedCapabilities = 0x7ffff;

const targetPolicies = [
  {
    hostPlatform: "darwin",
    hostArchitecture: "arm64",
    id: "aarch64-macos",
    architecture: "aarch64",
    os: "macos",
    abi: "none",
    rustTarget: "aarch64-apple-darwin",
    zigTarget: /^aarch64-macos\.(\d+\.\d+(?:\.\d+)?)\.\.\.[^-]+-none$/,
    library: "lib/libmetask_agentcore.a",
    optimize: "ReleaseSafe",
    systemLibraries: [],
    lock: path.join("build_support", "agentcore-bundle.macos.lock.json"),
  },
  {
    hostPlatform: "win32",
    hostArchitecture: "x64",
    id: "x86_64-windows-gnu",
    architecture: "x86_64",
    os: "windows",
    abi: "gnu",
    rustTarget: "x86_64-pc-windows-gnu",
    zigTarget: /^x86_64-windows\.[a-z0-9_]+\.\.\.[a-z0-9_]+-gnu$/,
    library: "lib/metask_agentcore.lib",
    optimize: "ReleaseSmall",
    systemLibraries: ["advapi32", "crypt32"],
    lock: path.join("build_support", "agentcore-bundle.windows.lock.json"),
  },
];

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

function requireStringArray(value, field) {
  requireValue(Array.isArray(value), `${field} must be an array`);
  for (const [index, item] of value.entries())
    requireString(item, `${field}[${index}]`);
}

function requireSafePayloadPath(value, field) {
  const relativePath = requireString(value, field);
  requireValue(
    Buffer.byteLength(relativePath) <= 1024,
    `${field} exceeds 1024 bytes`,
  );
  requireValue(
    !relativePath.includes("\0") && !relativePath.includes("\\"),
    `${field} contains an unsafe separator`,
  );
  requireValue(
    /^[A-Za-z0-9._/-]+$/.test(relativePath),
    `${field} contains unsupported path characters`,
  );
  requireValue(
    !path.posix.isAbsolute(relativePath) &&
      path.posix.normalize(relativePath) === relativePath &&
      !relativePath.endsWith("/") &&
      relativePath
        .split("/")
        .every(
          (segment) => segment !== "" && segment !== "." && segment !== "..",
        ),
    `${field} must be a normalized relative file path`,
  );
  requireValue(
    relativePath !== "manifest.json",
    "manifest.json cannot list itself as a payload",
  );
  return relativePath;
}

function expectedBundleEntries(payloadPaths) {
  const entries = new Set(["manifest.json", ...payloadPaths]);
  for (const relativePath of payloadPaths) {
    const segments = relativePath.split("/");
    for (let index = 1; index < segments.length; index += 1)
      entries.add(`${segments.slice(0, index).join("/")}/`);
  }
  return [...entries].sort();
}

function policyForHost(platform, architecture) {
  const policy = targetPolicies.find(
    (candidate) =>
      candidate.hostPlatform === platform &&
      candidate.hostArchitecture === architecture,
  );
  if (!policy)
    throw new Error(
      `unsupported AgentCore host target: ${architecture}-${platform}`,
    );
  return policy;
}

function policyForTargetId(targetId) {
  const policy = targetPolicies.find((candidate) => candidate.id === targetId);
  if (!policy)
    throw new Error(`unsupported AgentCore bundle target: ${targetId}`);
  return policy;
}

export async function loadLockedAgentCoreManifest(repositoryRoot, targetId) {
  const policy = policyForTargetId(targetId);
  const bytes = await readFile(path.join(repositoryRoot, policy.lock), "utf8");
  return { bytes, manifest: JSON.parse(bytes), policy };
}

export async function readAgentCoreBundleTargetId(bundleRoot) {
  const bytes = await readFile(path.join(bundleRoot, "manifest.json"), "utf8");
  const manifest = JSON.parse(bytes);
  return requireString(manifest?.target?.id, "target.id");
}

async function sha256(filePath) {
  const metadata = await stat(filePath);
  requireValue(
    metadata.size <= maxPayloadBytes,
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
  requireValue(
    !(await lstat(bundleRoot)).isSymbolicLink(),
    "AgentCore bundle root must not be a symbolic link",
  );
  const root = await realpath(bundleRoot);
  const manifestPath = path.join(root, "manifest.json");
  requireValue(
    (await stat(manifestPath)).size <= maxManifestBytes,
    "AgentCore manifest exceeds 1 MiB",
  );

  let manifest;
  let manifestBytes;
  try {
    manifestBytes = await readFile(manifestPath, "utf8");
    manifest = JSON.parse(manifestBytes);
  } catch (error) {
    throw new Error(`invalid AgentCore manifest: ${error.message}`, {
      cause: error,
    });
  }
  requireExactKeys(
    manifest,
    [
      "schema_version",
      "vendor",
      "name",
      "version",
      "source",
      "toolchain",
      "target",
      "build",
      "link",
      "contract",
      "files",
    ],
    "manifest",
  );
  requireExactKeys(manifest.source, ["commit", "dirty"], "source");
  requireExactKeys(manifest.toolchain, ["zig_version"], "toolchain");
  requireExactKeys(
    manifest.target,
    ["id", "architecture", "os", "abi", "zig_target", "rust_target"],
    "target",
  );
  requireExactKeys(manifest.build, ["optimize", "strip"], "build");
  requireExactKeys(
    manifest.link,
    ["requires_c_runtime", "system_libraries", "system_frameworks"],
    "link",
  );
  requireExactKeys(
    manifest.contract,
    [
      "binary_abi_status",
      "binary_abi_version",
      "binary_abi_revision",
      "binary_abi_table_size",
      "capabilities",
    ],
    "contract",
  );
  if (options.expectedManifest) {
    requireValue(
      isDeepStrictEqual(manifest, options.expectedManifest),
      "AgentCore manifest does not match the repository lock",
    );
  }
  if (options.expectedManifestBytes !== undefined) {
    requireValue(
      manifestBytes === options.expectedManifestBytes,
      "AgentCore manifest bytes do not match the repository lock",
    );
  }

  requireValue(
    manifest.schema_version === 1,
    "unsupported AgentCore manifest schema",
  );
  requireValue(
    manifest.vendor === "metask" && manifest.name === "agentcore",
    "unexpected AgentCore bundle identity",
  );
  const version = requireString(manifest.version, "version");
  const commit = requireString(manifest.source.commit, "source.commit");
  requireValue(
    /^[0-9a-f]{40}$/.test(commit),
    "source.commit must be a full lowercase SHA",
  );
  requireValue(
    typeof manifest.source.dirty === "boolean",
    "source.dirty must be boolean",
  );
  requireValue(
    manifest.source.dirty === false,
    "AgentCore bundle must come from a clean source checkout",
  );
  const escapedCommitPrefix = commit.slice(0, 12);
  const versionPattern = new RegExp(
    `^[0-9]+\\.[0-9]+\\.[0-9]+-dev\\+${escapedCommitPrefix}${
      manifest.source.dirty ? "\\.dirty" : ""
    }$`,
  );
  requireValue(
    versionPattern.test(version),
    "AgentCore version does not match source identity",
  );

  const zigVersion = requireString(
    manifest.toolchain.zig_version,
    "toolchain.zig_version",
  );
  const policy = policyForHost(
    options.platform ?? process.platform,
    options.architecture ?? process.arch,
  );
  requireValue(
    manifest.target.id === policy.id,
    "bundle target id does not match its architecture and OS",
  );
  requireValue(
    manifest.target.os === policy.os,
    `bundle OS ${manifest.target.os} does not match ${policy.os}`,
  );
  requireValue(
    manifest.target.architecture === policy.architecture,
    `bundle architecture ${manifest.target.architecture} does not match ${policy.architecture}`,
  );
  requireValue(
    manifest.target.abi === policy.abi,
    "unsupported AgentCore target ABI",
  );
  const zigTarget = requireString(
    manifest.target.zig_target,
    "target.zig_target",
  );
  const zigTargetMatch = zigTarget.match(policy.zigTarget);
  requireValue(zigTargetMatch, "unsupported AgentCore resolved target");
  requireValue(
    manifest.target.rust_target === policy.rustTarget,
    "unsupported AgentCore Rust target",
  );
  requireValue(
    manifest.build.optimize === policy.optimize,
    "unsupported AgentCore optimize mode",
  );
  requireValue(
    manifest.build.strip === true,
    "AgentCore bundle must be stripped",
  );
  requireValue(
    manifest.link.requires_c_runtime === true,
    "AgentCore bundle must require the C runtime",
  );
  requireStringArray(manifest.link.system_libraries, "link.system_libraries");
  requireStringArray(manifest.link.system_frameworks, "link.system_frameworks");
  requireValue(
    isDeepStrictEqual(manifest.link.system_libraries, policy.systemLibraries) &&
      manifest.link.system_frameworks.length === 0,
    "unsupported AgentCore system link inputs",
  );
  requireValue(
    manifest.contract.binary_abi_status === "experimental",
    "unsupported AgentCore binary ABI status",
  );
  requireValue(
    manifest.contract.binary_abi_version === supportedAbiVersion,
    "unsupported AgentCore binary ABI",
  );
  requireValue(
    manifest.contract.binary_abi_revision === supportedAbiRevision,
    "unsupported AgentCore binary ABI revision",
  );
  requireValue(
    manifest.contract.binary_abi_table_size === supportedAbiTableSize,
    "unsupported AgentCore binary ABI table size",
  );
  requireValue(
    manifest.contract.capabilities === supportedCapabilities,
    "unsupported AgentCore capability set",
  );

  requireValue(
    Array.isArray(manifest.files),
    "AgentCore manifest files must be an array",
  );
  requireValue(
    manifest.files.length > 0 && manifest.files.length <= maxPayloadFiles,
    "AgentCore manifest file count is out of bounds",
  );
  const declaredFiles = manifest.files.map((file, index) => {
    requireExactKeys(file, ["path", "sha256"], `files[${index}]`);
    const relativePath = requireSafePayloadPath(
      file.path,
      `files[${index}].path`,
    );
    requireValue(
      /^[0-9a-f]{64}$/.test(file.sha256),
      `invalid checksum for ${relativePath}`,
    );
    return relativePath;
  });
  requireValue(
    new Set(declaredFiles).size === declaredFiles.length,
    "AgentCore manifest contains a duplicate payload path",
  );
  requireValue(
    new Set(declaredFiles.map((relativePath) => relativePath.toLowerCase()))
      .size === declaredFiles.length,
    "AgentCore manifest contains a case-colliding payload path",
  );

  const actualEntries = (await listBundleEntries(root)).sort();
  requireValue(
    isDeepStrictEqual(actualEntries, expectedBundleEntries(declaredFiles)),
    "AgentCore bundle filesystem contains missing or unknown entries",
  );
  for (const file of manifest.files) {
    const actual = await sha256(path.join(root, file.path));
    requireValue(
      actual === file.sha256,
      `AgentCore checksum mismatch: ${file.path}`,
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

  let symbols = options.symbols;
  if (symbols === undefined && policy.os === "macos") {
    symbols = (
      await execFileAsync("nm", ["-gU", path.join(root, policy.library)], {
        encoding: "utf8",
        maxBuffer: 16 * 1024 * 1024,
      })
    ).stdout;
  }
  if (symbols !== undefined) {
    const discoveryMatches =
      symbols.match(/\b_?metask_agentcore_get_api\b/g) ?? [];
    requireValue(
      discoveryMatches.length === 1,
      "AgentCore bundle must expose exactly one revision 7 discovery symbol",
    );
    requireValue(
      !/\b_?metacodes_agentcore_get_api\b/.test(symbols),
      "AgentCore bundle exposes the obsolete revision 2 discovery symbol",
    );
  }

  return {
    root,
    manifest,
    payloadFiles: declaredFiles,
    target: zigTarget,
    deploymentTarget: zigTargetMatch[1] ?? null,
    libraryPath: path.join(root, policy.library),
  };
}
